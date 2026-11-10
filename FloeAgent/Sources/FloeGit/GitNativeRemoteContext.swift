// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import libgit2

/// One operation's callback lifetime. This owns no authorization policy: the
/// caller resolves an approved host-bound credential through existing stores.
/// The lock protects the borrowed remote pointer from cancellation/free races.
final class GitNativeRemoteContext: @unchecked Sendable {
    let authentication: GitRemoteAuthentication
    private let progress: (@Sendable (GitRemoteProgress) -> Void)?
    private let lock = NSLock()
    private var stopped = false
    private var borrowedRemote: OpaquePointer?
    private var firstFailure: GitRemoteFailure?
    private var authenticationSupplied = false
    private var credentialCount = 0
    private var acceptedReferences = [String]()
    private var sentBytes: Int64 = 0
    init(authentication: GitRemoteAuthentication, progress: (@Sendable (GitRemoteProgress) -> Void)? = nil) {
        self.authentication = authentication; self.progress = progress
    }
    var isCancelled: Bool { lock.withLock { stopped } }
    var failure: GitRemoteFailure? { lock.withLock { firstFailure } }
    var credentialSubmissions: Int { lock.withLock { credentialCount } }
    var transmittedBytes: Int64 { lock.withLock { sentBytes } }
    var updatedReferences: [String] { lock.withLock { acceptedReferences } }
    func fail(_ error: GitRemoteFailure) { lock.withLock { if firstFailure == nil { firstFailure = error } } }
    func register(remote: OpaquePointer) {
        lock.withLock { borrowedRemote = remote; if stopped { git_remote_stop(remote) } }
    }
    /// Must happen before git_remote_free, even on failure/cancellation.
    func unregister(remote: OpaquePointer) { lock.withLock { if borrowedRemote == remote { borrowedRemote = nil } } }
    func cancel() {
        lock.withLock { stopped = true; if let remote = borrowedRemote { git_remote_stop(remote) } }
    }
    func beginAuthenticationRound() { lock.withLock { authenticationSupplied = false } }
    func ensureActive() throws { if isCancelled || Task.isCancelled { throw CancellationError() } }
    func throwRecordedFailure() throws {
        try ensureActive()
        if let failure { throw failure }
    }
    func withCallbacks<Result>(_ operation: (git_remote_callbacks) throws -> Result) throws -> Result {
        var callbacks = git_remote_callbacks()
        try Self.check(git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION)))
        callbacks.credentials = Self.credentials
        callbacks.certificate_check = Self.certificate
        callbacks.transfer_progress = Self.receiving
        callbacks.push_transfer_progress = Self.sending
        callbacks.sideband_progress = Self.sideband
        callbacks.push_update_reference = Self.referenceUpdated
        callbacks.payload = Unmanaged.passUnretained(self).toOpaque()
        return try withExtendedLifetime(self) { try operation(callbacks) }
    }
    static func requireNativeSSH(for endpoint: GitRemoteEndpoint) throws {
        guard endpoint.transport == .ssh else { return }
        guard git_libgit2_feature_backend(GIT_FEATURE_SSH).map({ String(cString: $0) }) == "libssh2" else {
            throw GitRemoteFailure.nativeSSHUnavailable
        }
    }
    private static func check(_ value: Int32) throws {
        guard value >= 0 else { throw FloeError.internalError("Could not initialize Git transport callbacks") }
    }
    private static func context(_ raw: UnsafeMutableRawPointer?) -> GitNativeRemoteContext? {
        raw.map { Unmanaged<GitNativeRemoteContext>.fromOpaque($0).takeUnretainedValue() }
    }
    private func report(_ value: GitRemoteProgress) {
        if value.phase == .sending { lock.withLock { sentBytes = max(sentBytes, value.bytes) } }
        if !isCancelled { progress?(value) }
    }
    private func admitCredential() -> Bool {
        lock.withLock {
            credentialCount += 1
            guard !authenticationSupplied else { return false }
            authenticationSupplied = true; return true
        }
    }
    private static let credentials: git_credential_acquire_cb = { output, rawURL, rawUsername, allowed, raw in
        guard let box = context(raw), let output, let rawURL else { return GIT_EUSER.rawValue }
        if box.isCancelled { return GIT_EUSER.rawValue }
        let url = String(cString: rawURL), requestedUsername = rawUsername.map { String(cString: $0) }
        guard box.authentication.endpoint.permitsCredentialCallback(url, username: requestedUsername) else {
            box.fail(.credentialHostMismatch); return GIT_EAUTH.rawValue
        }
        switch box.authentication.material {
        case .anonymous:
            box.fail(.credentialsRequired); return GIT_EAUTH.rawValue
        case .https(let username, let password):
            if allowed & GIT_CREDENTIAL_USERNAME.rawValue != 0 {
                return git_credential_username_new(output, username)
            }
            guard allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0,
                  box.admitCredential(), let value = String(data: password, encoding: .utf8) else {
                box.fail(.authenticationRejected); return GIT_EAUTH.rawValue
            }
            return git_credential_userpass_plaintext_new(output, username, value)
        case .sshPassword(let username, let password, _):
            guard requestedUsername == nil || requestedUsername == username else {
                box.fail(.credentialHostMismatch); return GIT_EAUTH.rawValue
            }
            if allowed & GIT_CREDENTIAL_USERNAME.rawValue != 0 {
                return git_credential_username_new(output, username)
            }
            guard allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0,
                  box.admitCredential(), let value = String(data: password, encoding: .utf8) else {
                box.fail(.authenticationRejected); return GIT_EAUTH.rawValue
            }
            return git_credential_userpass_plaintext_new(output, username, value)
        case .ssh(let username, let key, let passphrase, _):
            guard requestedUsername == nil || requestedUsername == username else {
                box.fail(.credentialHostMismatch); return GIT_EAUTH.rawValue
            }
            if allowed & GIT_CREDENTIAL_USERNAME.rawValue != 0 {
                return git_credential_username_new(output, username)
            }
            guard allowed & GIT_CREDENTIAL_SSH_MEMORY.rawValue != 0,
                  box.admitCredential(), let privateKey = String(data: key, encoding: .utf8) else {
                box.fail(.authenticationRejected); return GIT_EAUTH.rawValue
            }
            let pass = passphrase.flatMap { String(data: $0, encoding: .utf8) }
            if let pass {
                return git_credential_ssh_key_memory_new(output, username, nil, privateKey, pass)
            }
            return git_credential_ssh_key_memory_new(output, username, nil, privateKey, nil)
        }
    }
    private static let certificate: git_transport_certificate_check_cb = { certificate, valid, host, raw in
        guard let box = context(raw), let certificate, let host else { return GIT_ECERTIFICATE.rawValue }
        if box.isCancelled { return GIT_EUSER.rawValue }
        let remoteHost = String(cString: host).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard remoteHost == box.authentication.endpoint.host else {
            box.fail(.credentialHostMismatch); return GIT_ECERTIFICATE.rawValue
        }
        if box.authentication.endpoint.transport == .https {
            guard valid == 1 else { box.fail(.untrustedHTTPSCertificate); return GIT_ECERTIFICATE.rawValue }
            return 0
        }
        guard certificate.pointee.cert_type == GIT_CERT_HOSTKEY_LIBSSH2 else {
            box.fail(.invalidHostKey); return GIT_ECERTIFICATE.rawValue
        }
        let key = UnsafeRawPointer(certificate).assumingMemoryBound(to: git_cert_hostkey.self).pointee
        guard key.type.rawValue & GIT_CERT_SSH_SHA256.rawValue != 0 else {
            box.fail(.invalidHostKey); return GIT_ECERTIFICATE.rawValue
        }
        let fingerprint = withUnsafeBytes(of: key.hash_sha256) { "SHA256:" + Data($0).base64EncodedString().replacingOccurrences(of: "=", with: "") }
        let keyType: String = switch key.raw_type {
        case GIT_CERT_SSH_RAW_TYPE_RSA: "ssh-rsa"
        case GIT_CERT_SSH_RAW_TYPE_DSS: "ssh-dss"
        case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_256: "ecdsa-sha2-nistp256"
        case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_384: "ecdsa-sha2-nistp384"
        case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_521: "ecdsa-sha2-nistp521"
        case GIT_CERT_SSH_RAW_TYPE_KEY_ED25519: "ssh-ed25519"
        default: "unknown"
        }
        let username: String, expected: String?
        switch box.authentication.material {
        case .ssh(let user, _, _, let fingerprint), .sshPassword(let user, _, let fingerprint): username = user; expected = fingerprint
        default: box.fail(.credentialsRequired); return GIT_ECERTIFICATE.rawValue
        }
        guard let expected else {
            box.fail(.hostKeyNotTrusted(.init(host: box.authentication.endpoint.host, port: box.authentication.endpoint.port,
                user: username, keyType: keyType, fingerprintSHA256: fingerprint)))
            return GIT_ECERTIFICATE.rawValue
        }
        guard expected == fingerprint else {
            box.fail(.hostKeyChanged(expected: expected, received: fingerprint)); return GIT_ECERTIFICATE.rawValue
        }
        return 0
    }
    private static let receiving: git_indexer_progress_cb = { stats, raw in
        guard let box = context(raw), let stats else { return GIT_EUSER.rawValue }
        if box.isCancelled { return GIT_EUSER.rawValue }
        let value = stats.pointee
        box.report(.init(phase: value.indexed_objects < value.received_objects ? .indexing : .receiving,
            completedObjects: Int(value.received_objects), totalObjects: Int(value.total_objects), bytes: Int64(clamping: value.received_bytes)))
        return 0
    }
    private static let sending: git_push_transfer_progress_cb = { current, total, bytes, raw in
        guard let box = context(raw) else { return GIT_EUSER.rawValue }
        if box.isCancelled { return GIT_EUSER.rawValue }
        box.report(.init(phase: .sending, completedObjects: Int(current), totalObjects: Int(total), bytes: Int64(clamping: bytes)))
        return 0
    }
    private static let sideband: git_transport_message_cb = { _, _, raw in
        guard let box = context(raw) else { return GIT_EUSER.rawValue }
        return box.isCancelled ? GIT_EUSER.rawValue : 0
    }
    private static let referenceUpdated: git_push_update_reference_cb = { ref, status, raw in
        guard let box = context(raw), let ref else { return GIT_EUSER.rawValue }
        guard status == nil else { box.fail(.remoteRejected); return GIT_EUSER.rawValue }
        let name = String(cString: ref)
        box.lock.withLock { box.acceptedReferences.append(name) }
        return box.isCancelled ? GIT_EUSER.rawValue : 0
    }
}
