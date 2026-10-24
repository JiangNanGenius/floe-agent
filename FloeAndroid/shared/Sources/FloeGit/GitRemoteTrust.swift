// SPDX-License-Identifier: MPL-2.0
//
// GitRemoteTrust — Android platform-trust seam for native network Git
// (lane job-f74b2a485e9a4434, G04-R2 continuation of job-6cb7731a07774f01).
//
// WHAT THIS FILE IS
//   The native half of the "trusted platform trust bundle" boundary for the
//   vendored libgit2 1.9.2 + mbedTLS 3.6.7 overlay on Android. The Kotlin
//   platform adapter (app/src/main/kotlin/com/floe/android/host/
//   GitPlatformTrust.kt) derives the PEM bundle from the ACTUAL default
//   X509TrustManager (TrustManagerFactory — the stable public interface to
//   the current, updatable Conscrypt APEX + system trust the OS exposes to
//   apps; see https://source.android.com/docs/core/ota/modular-system/
//   conscrypt). This module verifies that bundle's ownership, size, digest
//   and certificate count and installs it into the libgit2 TLS backend
//   through the Floe-authored non-variadic C shim (Vendor/Git/floe-shim)
//   before any remote operation. Offline operations (status/diff/stage/
//   commit/branch/merge/conflict/discard) never pass through this seam and
//   stay fully usable with no network trust bound.
//
// SOURCE-PROVEN FACTS about the pinned backend (verified in lane against
// shared/Vendor/Git/libgit2 52287b09; no repository-wide audit was run):
//   * streams/mbedtls.c always verifies: `git_mbedtls_stream_global_init`
//     sets MBEDTLS_SSL_VERIFY_OPTIONAL so the chain is kept, and
//     `mbedtls_connect` → `verify_server_cert` fails the connection with
//     GIT_ECERTIFICATE whenever the platform-verify result is non-zero.
//   * httpclient.c `server_connect_stream` only softens a verification
//     failure through a caller-provided certificate_check callback; the
//     FloeGit mirrors register NO certificate_check callback, so an invalid
//     chain always fails. The seam keeps that property (never "return 0").
//   * The pinned source NEVER reads `http.sslVerify`, `http.sslCAInfo` or
//     `http.sslCAPath` from any config layer (grep over src/: only
//     `http.followRedirects` (remote.c) and `http.proxy`/`remote.<name>.
//     proxy` plus URL-scoped `http.<url>.proxy` are read). So repository
//     config cannot turn TLS off in this build, and there is no config
//     route to point the backend at an arbitrary CA: trust can only be
//     installed through GIT_OPT_SET_SSL_CERT_LOCATIONS (settings.c,
//     mbedTLS branch) — which is exactly this seam.
//   * remote.c `git_remote_connect_options_normalize` treats
//     follow_redirects == 0 as UNSPECIFIED and then consults the
//     repository's `http.followRedirects` (lookup_redirect_config); a repo
//     can therefore raise the policy to ALL. GIT_REMOTE_REDIRECT_NONE is
//     value 1, survives normalize (skipping the config consult) and makes
//     transports/http.c pass allow_offsite=false into
//     util/net.c `git_net_url_apply_redirect`, which rejects every
//     cross-host redirect (same-HTTPS-host redirects keep working, and a
//     downgrade to a non-https scheme is always rejected).
//   * transports/http.c keeps the connected server URL after a redirect,
//     while the credential callback (transports/smart.c
//     git_transport_smart_credentials) is invoked with the transport's
//     ORIGINAL url string. A callback that ignored its url argument (as
//     the byte-exact iOS mirror did — on iOS the HTTPS+github.com pin and
//     INITIAL redirect default were upstream policy) therefore cannot see
//     a redirect widening. The seam closes that with BOTH layers:
//       1. the pinned NONE redirect policy above (the network can never be
//          re-pointed off the validated host), and
//       2. a callback-side scope guard (GitRemoteOperationPolicy) that
//          fails closed to GIT_PASSTHROUGH if a request ever carries a
//          URL outside the product contract.
//
// PLATFORM BEHAVIOR
//   * Android (GIT_HTTPS_MBEDTLS overlay): remote operations are gated.
//     Without a bound, verified bundle they fail with a typed
//     FloeError.invalidConfiguration BEFORE any socket is opened —
//     "honestly unavailable", never a successful placeholder.
//   * Apple/SecureTransport (macOS host qualification cohort only — this
//     seam is never compiled into the iOS product, which keeps its
//     upstream libgit2 package and its OS trust): prepareRemoteOperation()
//     is a documented no-op passthrough, mirroring the original iOS
//     behavior where the TLS backend inherently uses OS trust and no
//     CA-location option exists (settings.c fails that option on non-
//     OpenSSL/mbedTLS backends). install/retire/verify still work here and
//     the focused offline suites exercise them.
//
// LIFECYCLE
//   The libgit2 runtime epoch is owned by LocalGitService.withRuntime
//   (git_libgit2_init/git_libgit2_shutdown per operation). The mbedTLS
//   global CA chain is freed when the refcount drops, so the seam does NOT
//   install once at bind time: every remote operation re-verifies the
//   bundle bytes and re-installs the CA chain inside its own epoch.
//   install() binds + verifies the record up front (fail fast); a later
//   file change/removal makes the NEXT remote operation fail closed and
//   revokes the binding until Main composes a fresh export (new service/
//   root binding → Kotlin re-derives from the live OS trust → retire the
//   stale identity, install the new one). No stale file is ever trusted
//   "forever".

import Foundation
import Crypto
import FloeCore
import libgit2
import FloeGitShim

/// Immutable identity of one exported platform-trust bundle, as produced by
/// the Kotlin adapter (GitPlatformTrust.GitTrustBundle) and handed across
/// the JNI boundary by Main's later Core composition. Value type: nothing
/// here is mutable state, and every field is validated again at verify time.
public struct GitTrustedBundleRecord: Hashable, Sendable {
    /// Stable identifier for one export generation. The adapter derives it
    /// from the bundle digest; retire() is guarded by it so a late retire
    /// can never unbind a newer record.
    public let bundleID: String
    /// Absolute file URL of the bundle inside the app's private storage.
    public let bundleFileURL: URL
    /// App-private root this bundle must live under (Context filesDir on
    /// Android). Checked raw AND symlink-resolved.
    public let privateRootPath: String
    /// Lowercase 64-char SHA-256 hex of the exact bundle bytes.
    public let expectedSHA256Hex: String
    /// PEM certificate count the adapter counted at export time.
    public let expectedCertificateCount: Int
    /// Exact byte count the adapter measured at export time.
    public let expectedByteCount: Int
    /// Wall-clock milliseconds at export (diagnostic staleness only; the
    /// seam never trusts a bundle by age, only by digest).
    public let exportedAtUnixMillis: Int64

    public init(
        bundleID: String,
        bundleFileURL: URL,
        privateRootPath: String,
        expectedSHA256Hex: String,
        expectedCertificateCount: Int,
        expectedByteCount: Int,
        exportedAtUnixMillis: Int64
    ) {
        self.bundleID = bundleID
        self.bundleFileURL = bundleFileURL
        self.privateRootPath = privateRootPath
        self.expectedSHA256Hex = expectedSHA256Hex
        self.expectedCertificateCount = expectedCertificateCount
        self.expectedByteCount = expectedByteCount
        self.exportedAtUnixMillis = exportedAtUnixMillis
    }
}

/// Typed, user-content-free failure vocabulary for the seam itself. The
/// remote-operation path maps these to the existing FloeError vocabulary
/// (see `prepareRemoteOperation`); direct ports surface them raw.
public enum GitRemoteTrustError: Error, Equatable, Sendable {
    case trustUnbound
    case invalidRecord(reason: String)
    case bundlePathOutsidePrivateRoot
    case bundleLeafNameMismatch(expected: String, observed: String)
    case bundleNotARegularFile
    case bundleTooLarge(limitBytes: Int)
    case bundleEmpty
    case byteCountMismatch(expected: Int, observed: Int)
    case digestMismatch(expected: String, observed: String)
    case certificateCountMismatch(declared: Int, observed: Int)
    case malformedBundlePEM(detail: String)
    case backendInstallationFailed(reason: String)
    case replacementRequiresRetire(activeBundleID: String)
    case recordIdentityMismatch(expectedBundleID: String, activeBundleID: String)
}

/// The trust binding. Synchronous because LocalGitService's operation path
/// is synchronous inside its actor; all state sits behind one lock and the
/// record type is immutable. There is exactly one binding per process —
/// this is the native half of the SINGLE platform-trust authority, not a
/// second credential or config store.
public final class GitRemoteTrust: @unchecked Sendable {
    /// Shared production binding.
    public static let shared = GitRemoteTrust()

    private static let remoteOperationLock = NSRecursiveLock()

    /// The CA chain/config are shared by every libgit2 stream in this
    /// process. Reloading trust must not free a chain used by another
    /// repository's live TLS stream. A recursive lock also covers the
    /// prepareRemoteOperation call inside an admitted remote operation.
    static func withExclusiveRemoteOperation<T>(_ body: () throws -> T) rethrows -> T {
        remoteOperationLock.lock()
        defer { remoteOperationLock.unlock() }
        return try body()
    }


    /// Hard bounds (mirror of GitPlatformTrust.kt constants; the native
    /// side enforces them independently of the exporter): a trust bundle
    /// is at most 4 MiB and 4096 certificates, and must contain at least
    /// one.
    public static let bundleLimitBytes = 4 * 1024 * 1024
    public static let certificateLimitCount = 4096
    /// The exact leaf name the adapter writes and the native side accepts.
    public static let bundleFileName = "platform-trust-bundle.pem"

    private static let pemBegin = Array("-----BEGIN CERTIFICATE-----".utf8)
    private static let pemEnd = Array("-----END CERTIFICATE-----".utf8)

    private let lock = NSLock()
    private var binding: GitTrustedBundleRecord?

    /// Internal isolated instance for the focused offline suites (the
    /// production surface is `shared`; tests must never race its binding).
    init() {}

    public var currentBundleRecord: GitTrustedBundleRecord? {
        lock.lock()
        defer { lock.unlock() }
        return binding
    }

    /// Typed INSTALL port (for Main's later Core composition at actual
    /// service/root binding): verifies ownership, size, digest and PEM
    /// count now, and binds the immutable record. Does not touch the
    /// libgit2 runtime (CA installation happens per remote operation
    /// inside its own runtime epoch, see file header). Re-binding a
    /// DIFFERENT identity while one is active requires an explicit
    /// retire(); re-installing the SAME identity re-verifies the file and
    /// keeps the binding (idempotent refresh after a process-side change
    /// attempt).
    @discardableResult
    public func install(_ record: GitTrustedBundleRecord) throws -> GitTrustedBundleRecord {
        let resolved = try Self.verify(record)
        lock.lock()
        defer { lock.unlock() }
        if let active = binding, active.bundleID != record.bundleID {
            throw GitRemoteTrustError.replacementRequiresRetire(activeBundleID: active.bundleID)
        }
        _ = resolved // ownership/digest/count proven; install-to-backend is per operation
        binding = record
        return record
    }

    /// Typed RETIRE port: clears the binding, guarded by identity so a
    /// delayed retire for a superseded record can never unbind the current
    /// one. Returns false when nothing was bound. The bundle FILE is the
    /// adapter's to delete (Kotlin clearBundle); deleting it while bound
    /// simply makes the next remote operation fail closed.
    public func retire(expectedBundleID: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let active = binding else { return false }
        guard active.bundleID == expectedBundleID else {
            throw GitRemoteTrustError.recordIdentityMismatch(
                expectedBundleID: expectedBundleID,
                activeBundleID: active.bundleID
            )
        }
        binding = nil
        return true
    }

    /// Remote-operation gate + per-epoch CA installation. Called by
    /// LocalGitService clone/fetch/push/pull INSIDE `withRuntime` (after
    /// git_libgit2_init succeeded). Android: requires a bound record,
    /// re-verifies the exact bytes, re-installs the CA chain through the
    /// shim, and REVOKES the binding on any verification or backend
    /// failure so subsequent operations fail as unbound until a fresh
    /// export is installed. Any other platform (the macOS host cohort for
    /// this shared module): documented no-op passthrough — the Secure-
    /// Transport backend inherently uses Apple platform trust, exactly the
    /// pre-seam iOS production behavior.
    public func prepareRemoteOperation() throws {
        #if os(Android)
        Self.remoteOperationLock.lock()
        defer { Self.remoteOperationLock.unlock() }
        do {
            try Self.enforceRemoteTrust(bindingProvider: { [weak self] in self?.currentBundleRecord })
        } catch let error as GitRemoteTrustError {
            if error != .trustUnbound {
                lock.lock()
                binding = nil
                lock.unlock()
            }
            throw Self.floeError(for: error)
        }
        #else
        // Apple host qualification cohort: no mbedTLS backend, no CA-location
        // option (settings.c fails GIT_OPT_SET_SSL_CERT_LOCATIONS for this
        // backend). Platform trust is inherent here; the seam stays honest by
        // not pretending to install. Behavior equals the untouched iOS mirror.
        #endif
    }

    /// Platform-independent body of prepareRemoteOperation, split out so
    /// the focused offline suites can exercise the full Android decision
    /// table deterministically on any host.
    internal static func enforceRemoteTrust(
        bindingProvider: () -> GitTrustedBundleRecord?,
        installBackend: (GitTrustedBundleRecord, String) throws -> Void = { record, resolvedPath in
            try installCAChain(record: record, resolvedBundlePath: resolvedPath)
        }
    ) throws {
        guard let record = bindingProvider() else {
            throw GitRemoteTrustError.trustUnbound
        }
        let resolved = try verify(record)
        try installBackend(record, resolved)
    }

    /// Full verification of one record against the real file: descriptor
    /// form, raw + symlink-resolved app-private ownership, exact leaf name,
    /// regular file, bounded streaming read, SHA-256 digest, byte count and
    /// PEM certificate count. Returns the resolved bundle path that passed
    /// verification (callers install THAT path, not any re-resolved value).
    internal static func verify(_ record: GitTrustedBundleRecord) throws -> String {
        guard record.privateRootPath.hasPrefix("/"),
              !record.privateRootPath.isEmpty else {
            throw GitRemoteTrustError.invalidRecord(reason: "private root must be absolute")
        }
        let hex = record.expectedSHA256Hex
        guard hex.count == 64, hex.allSatisfy({ Self.isLowercaseHexDigit($0) }) else {
            throw GitRemoteTrustError.invalidRecord(reason: "digest must be 64 lowercase hex characters")
        }
        guard record.expectedCertificateCount >= 1,
              record.expectedCertificateCount <= certificateLimitCount else {
            throw GitRemoteTrustError.invalidRecord(reason: "certificate count outside supported bounds")
        }
        guard record.expectedByteCount >= 1, record.expectedByteCount <= bundleLimitBytes else {
            throw GitRemoteTrustError.invalidRecord(reason: "byte count outside supported bounds")
        }
        guard !record.bundleID.isEmpty else {
            throw GitRemoteTrustError.invalidRecord(reason: "bundle id is empty")
        }
        guard record.bundleFileURL.isFileURL, record.bundleFileURL.path.hasPrefix("/") else {
            throw GitRemoteTrustError.invalidRecord(reason: "bundle path must be an absolute file URL")
        }

        let bundlePath = record.bundleFileURL.path
        // Raw prefix: the exporter and this verifier receive the same
        // canonical strings through the trusted bridge, so the literal
        // containment must already hold.
        guard bundlePath.hasPrefix(record.privateRootPath + "/") else {
            throw GitRemoteTrustError.bundlePathOutsidePrivateRoot
        }
        guard record.bundleFileURL.lastPathComponent == bundleFileName else {
            throw GitRemoteTrustError.bundleLeafNameMismatch(
                expected: bundleFileName,
                observed: record.bundleFileURL.lastPathComponent
            )
        }
        // Symlink-resolved prefix: a swapped-in symlink escaping the
        // private root is rejected before anything is opened.
        let resolvedBundleURL = record.bundleFileURL.resolvingSymlinksInPath()
        let resolvedRoot = URL(fileURLWithPath: record.privateRootPath).resolvingSymlinksInPath().path
        let resolvedBundlePath = resolvedBundleURL.path
        guard resolvedBundlePath.hasPrefix(resolvedRoot + "/"), resolvedBundlePath != resolvedRoot else {
            throw GitRemoteTrustError.bundlePathOutsidePrivateRoot
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: resolvedBundlePath)
        } catch {
            throw GitRemoteTrustError.bundleNotARegularFile
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw GitRemoteTrustError.bundleNotARegularFile
        }

        // The limit is small (4 MiB) by contract, so the bounded read may
        // hold the verified bytes in memory for the digest and PEM count.
        let bundleData = try Self.readBounded(path: resolvedBundlePath, limit: bundleLimitBytes)
        let total = bundleData.count
        guard total > 0 else { throw GitRemoteTrustError.bundleEmpty }
        if total != record.expectedByteCount {
            throw GitRemoteTrustError.byteCountMismatch(expected: record.expectedByteCount, observed: total)
        }
        let digestHex = SHA256.hash(data: bundleData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digestHex == hex else {
            throw GitRemoteTrustError.digestMismatch(expected: hex, observed: digestHex)
        }
        let beginCount = Self.countMarker(data: bundleData, marker: Self.pemBegin)
        let endCount = Self.countMarker(data: bundleData, marker: Self.pemEnd)
        guard beginCount >= 1, beginCount == endCount else {
            throw GitRemoteTrustError.malformedBundlePEM(
                detail: "unbalanced PEM blocks (begin=\(beginCount), end=\(endCount))"
            )
        }
        guard beginCount == record.expectedCertificateCount else {
            throw GitRemoteTrustError.certificateCountMismatch(
                declared: record.expectedCertificateCount,
                observed: beginCount
            )
        }
        return resolvedBundlePath
    }

    /// Bounded sequential read of the bundle. Aborts past the limit before
    /// an attacker-sized file can be buffered; the whole (≤4 MiB) verified
    /// byte window is returned for digest + PEM counting.
    private static func readBounded(path: String, limit: Int) throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw GitRemoteTrustError.bundleNotARegularFile
        }
        defer { try? handle.close() }
        var buffer = Data()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            if buffer.count + chunk.count > limit {
                throw GitRemoteTrustError.bundleTooLarge(limitBytes: limit)
            }
            buffer.append(chunk)
        }
        return buffer
    }

    private static func isLowercaseHexDigit(_ character: Character) -> Bool {
        switch character {
        case "0"..."9", "a"..."f": return true
        default: return false
        }
    }

    private static func countMarker(data: Data, marker: [UInt8]) -> Int {
        guard !marker.isEmpty, data.count >= marker.count else { return 0 }
        var count = 0
        let bytes = [UInt8](data)
        var index = 0
        while index + marker.count <= bytes.count {
            var matched = true
            for offset in 0..<marker.count where bytes[index + offset] != marker[offset] {
                matched = false
                break
            }
            if matched {
                count += 1
                index += marker.count
            } else {
                index += 1
            }
        }
        return count
    }

    /// Install through the shim into the CURRENT libgit2 runtime epoch.
    /// Must only be called while git_libgit2_init()'s refcount is held.
    internal static func installCAChain(record: GitTrustedBundleRecord, resolvedBundlePath: String) throws {
        _ = record
        let result = resolvedBundlePath.withCString { pathPointer in
            floe_git_set_ssl_cert_locations(pathPointer, nil)
        }
        guard result == 0 else {
            throw GitRemoteTrustError.backendInstallationFailed(reason: Self.lastGitErrorMessage())
        }
    }

    private static func lastGitErrorMessage() -> String {
        guard let error = git_error_last()?.pointee.message else { return "unknown libgit2 error" }
        return SecretRedactor.redact(String(cString: UnsafePointer(error)))
    }

    /// Maps seam failures into the existing FloeError vocabulary of the
    /// Git tools without leaking paths, digests of user content or token
    /// material. The bundle digest itself is public-key material, but the
    /// messages stay minimal anyway.
    internal static func floeError(for error: GitRemoteTrustError) -> FloeError {
        switch error {
        case .trustUnbound:
            return FloeError.invalidConfiguration(
                FloeL10n.l("git.git_remote_trust.network_git_operations_require_the_platform")
            )
        case .invalidRecord(let reason):
            return FloeError.validationFailed("Git trust bundle record is invalid: \(reason)")
        case .bundlePathOutsidePrivateRoot, .bundleLeafNameMismatch:
            return FloeError.validationFailed("Git trust bundle must live inside the app-private trust directory under its exact bundle name")
        case .bundleNotARegularFile:
            return FloeError.syncUnavailable("Git trust bundle file is missing; network Git is unavailable until the platform trust is re-exported")
        case .bundleTooLarge(let limit):
            return FloeError.validationFailed("Git trust bundle exceeds the \(limit)-byte bound")
        case .bundleEmpty:
            return FloeError.validationFailed("Git trust bundle is empty; refusing to operate without platform trust")
        case .byteCountMismatch, .digestMismatch, .certificateCountMismatch, .malformedBundlePEM:
            return FloeError.syncUnavailable("Git trust bundle no longer matches the exported platform trust; it was revoked and network Git is unavailable until a fresh export")
        case .backendInstallationFailed(let reason):
            return FloeError.syncUnavailable("Git trust installation failed: \(reason)")
        case .replacementRequiresRetire(let activeID):
            return FloeError.invalidConfiguration("A Git trust bundle is already bound (\(activeID)); retire it before installing a replacement")
        case .recordIdentityMismatch(let expected, let active):
            return FloeError.invalidConfiguration("Git trust retire ignored: expected \(expected), bound \(active)")
        }
    }
}

/// Single authority for the remote-operation policy constants the mirrors
/// enforce. Kept pure (no libgit2 runtime state) so it is unit-testable
/// offline.
public enum GitRemoteOperationPolicy {
    /// Credential callback scope: exactly the LocalGitService.validateRemote
    /// product contract — https, github.com or a *.github.com host, and no
    /// userinfo. A request outside it must receive GIT_PASSTHROUGH so
    /// libgit2 fails with typed GIT_EAUTH instead of handing the leased
    /// token to another endpoint.
    public static func credentialScopeAllows(url: String?) -> Bool {
        guard let url, let parsed = URL(string: url) else { return false }
        guard parsed.scheme?.lowercased() == "https",
              let host = parsed.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com") else {
            return false
        }
        guard parsed.user == nil, parsed.password == nil else { return false }
        return true
    }

    /// The redirect-mode constant as the pinned libgit2 itself defines it
    /// (GIT_REMOTE_REDIRECT_NONE == 1; 0 would mean "unspecified" and let
    /// the repository's http.followRedirects decide — see file header).
    /// Provided by the C shim so Swift never spells the enum by hand.
    public static var pinnedRedirectNoneValue: Int32 {
        floe_git_redirect_policy_none_value()
    }

    public static func applyPinnedRedirects(to options: inout git_clone_options) {
        floe_git_fetch_options_forbid_offsite_redirects(&options.fetch_opts)
    }

    public static func applyPinnedRedirects(to options: inout git_fetch_options) {
        floe_git_fetch_options_forbid_offsite_redirects(&options)
    }

    public static func applyPinnedRedirects(to options: inout git_push_options) {
        floe_git_push_options_forbid_offsite_redirects(&options)
    }
}
