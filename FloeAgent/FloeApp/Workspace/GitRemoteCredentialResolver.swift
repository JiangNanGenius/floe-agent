// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeCore
import FloeGit
import FloePersistence
import FloeSecurity
import FloeSync
import FloeSSH

struct GitCredentialScope: Sendable, Hashable {
    let workspaceRoot: URL
    let workspaceID: UUID?
    let conversationID: UUID?
    var rootIdentity: String { workspaceRoot.standardizedFileURL.resolvingSymlinksInPath().path }
}
enum GitRemoteCredentialChoice: Codable, Sendable, Hashable {
    case automatic
    case anonymous
    case savedToken(id: UUID, username: String)
    case savedSSHHost(id: UUID)
}
struct GitCredentialOption: Sendable, Identifiable, Hashable {
    let id: UUID
    let label: String
}
enum GitCredentialConfigurationError: Error, Sendable, LocalizedError {
    case selectCredential, configureSSH, chooseSSHHost, hostMismatch, credentialChanged, unsupportedJump, trustRequired
    var errorDescription: String? {
        let text: (String, String) = switch self {
        case .selectCredential: ("请选择此仓库使用的凭据。", "Choose the credential for this repository.")
        case .configureSSH: ("请先添加此仓库的 SSH 连接，再继续。", "Add an SSH connection for this repository to continue.")
        case .chooseSSHHost: ("找到多个匹配的连接，请选择此仓库要使用的连接。", "Several connections match. Choose one for this repository.")
        case .hostMismatch: ("连接主机已变化，未发送已保存的凭据。", "The connection host changed. Saved credentials were not sent.")
        case .credentialChanged: ("连接配置已更新，请重试。", "Connection settings changed. Try again.")
        case .unsupportedJump: ("此连接需要跳板机。请选择可直接连接仓库的 SSH 连接。", "This connection requires a jump host. Choose a direct SSH connection for the repository.")
        case .trustRequired: ("请先确认此 SSH 主机的指纹。", "Verify this SSH host's fingerprint first.")
        }
        return FloeL10n.isChinese ? text.0 : text.1
    }
}

protocol GitBindingStorage: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ bytes: Data, account: String) throws
    func delete(_ account: String) throws
}
struct GitKeychainBindings: GitBindingStorage {
    // Only host-bound opaque selection metadata is stored here. Secret bytes
    // remain in the existing vault/profile accounts and are never duplicated.
    private let store = KeychainStore(service: CredentialVaultService.serviceName, synchronizable: false)
    func read(_ account: String) throws -> Data? {
        do { return try store.read(account: account) }
        catch KeychainStoreError.itemNotFound { return nil }
    }
    func write(_ bytes: Data, account: String) throws { try store.store(account: account, secret: bytes) }
    func delete(_ account: String) throws {
        do { try store.delete(account: account) } catch KeychainStoreError.itemNotFound {}
    }
}

/// Uses the existing vault, host metadata, known-host store and trust surface.
/// It is not an account store, host editor, or alternative approval system.
actor GitRemoteCredentialResolver {
    typealias SecretResolver = @Sendable (SecretReference) throws -> Data
    typealias TrustDecision = @Sendable (HostKeyChallenge) async -> Bool
    private struct Binding: Codable, Sendable, Equatable {
        let version: Int
        let rootIdentity: String
        let origin: String
        let choice: GitRemoteCredentialChoice
    }
    private struct Resolved: Sendable {
        let authentication: GitRemoteAuthentication
        let profile: RemoteHostProfile?
    }
    private let vault: CredentialVaultService
    private let credentials: CredentialStore
    private let hosts: RemoteHostStore
    private let github: GitHubCredentialStore
    private let bindings: any GitBindingStorage
    private let secret: SecretResolver

    init(vault: CredentialVaultService, credentials: CredentialStore, hosts: RemoteHostStore,
         github: GitHubCredentialStore = .init(), bindings: any GitBindingStorage = GitKeychainBindings(),
         secret: @escaping SecretResolver = { reference in
             try KeychainStore(service: CredentialVaultService.serviceName, synchronizable: reference.synchronizable).read(account: reference.keychainAccount)
         }) {
        self.vault = vault; self.credentials = credentials; self.hosts = hosts
        self.github = github; self.bindings = bindings; self.secret = secret
    }
    private func account(_ endpoint: GitRemoteEndpoint, scope: GitCredentialScope) -> String {
        "git.binding.v1." + FloeDigest.sha256Hex(Data((scope.rootIdentity + "\0" + endpoint.origin).utf8))
    }
    private func binding(_ endpoint: GitRemoteEndpoint, scope: GitCredentialScope) throws -> Binding? {
        guard let bytes = try bindings.read(account(endpoint, scope: scope)) else { return nil }
        guard bytes.count <= 16_384 else { throw GitCredentialConfigurationError.credentialChanged }
        let value = try JSONDecoder().decode(Binding.self, from: bytes)
        guard value.version == 1, value.rootIdentity == scope.rootIdentity, value.origin == endpoint.origin else { throw GitCredentialConfigurationError.hostMismatch }
        return value
    }
    func choice(for endpoint: GitRemoteEndpoint, scope: GitCredentialScope) throws -> GitRemoteCredentialChoice {
        try binding(endpoint, scope: scope)?.choice ?? .automatic
    }
    func save(_ choice: GitRemoteCredentialChoice, endpoint: GitRemoteEndpoint, scope: GitCredentialScope) async throws {
        try Task.checkCancellation()
        switch choice {
        case .automatic: try bindings.delete(account(endpoint, scope: scope)); return
        case .anonymous: guard endpoint.transport == .https else { throw GitCredentialConfigurationError.configureSSH }
        case .savedToken(let id, let username):
            guard endpoint.transport == .https, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let record = try await vault.metadata(.init(id: id)), Self.admits(record, endpoint: endpoint, scope: scope) else { throw GitCredentialConfigurationError.selectCredential }
        case .savedSSHHost(let id): _ = try await profile(id, endpoint: endpoint)
        }
        try Task.checkCancellation()
        try bindings.write(JSONEncoder().encode(Binding(version: 1, rootIdentity: scope.rootIdentity, origin: endpoint.origin, choice: choice)), account: account(endpoint, scope: scope))
    }
    func credentialOptions(endpoint: GitRemoteEndpoint, scope: GitCredentialScope) async throws -> [GitCredentialOption] {
        try await credentials.records().filter { Self.admits($0, endpoint: endpoint, scope: scope) }.map { .init(id: $0.id, label: $0.label) }
    }
    func hostOptions(endpoint: GitRemoteEndpoint) async throws -> [RemoteHostProfile] {
        let records = try await hosts.hosts()
        let matching = records.filter {
            $0.address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == endpoint.host
                && $0.port == endpoint.port && (endpoint.user == nil || endpoint.user == $0.user)
        }
        return try matching.map { try RemoteHostProfile(stored: $0) }.filter { Self.matches($0, endpoint: endpoint) }
    }
    static func admits(_ record: CredentialRecord, endpoint: GitRemoteEndpoint, scope: GitCredentialScope) -> Bool {
        guard endpoint.transport == .https, [.genericToken, .websitePassword].contains(record.kind) else { return false }
        switch record.owner {
        case .vault: break
        case .workspace(let id): guard id == scope.workspaceID else { return false }
        case .conversation(let id): guard id == scope.conversationID else { return false }
        }
        // An originless card may be explicitly chosen by native configuration.
        // It is never automatically selected, copied or rebound by model JSON.
        guard let origin = record.origin else { return true }
        guard let components = URLComponents(string: origin), components.scheme == "https",
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let bound = try? GitRemoteEndpoint(origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/.floe-origin") else { return false }
        return bound.origin == endpoint.origin
    }
    static func matches(_ profile: RemoteHostProfile, endpoint: GitRemoteEndpoint) -> Bool {
        let address = profile.address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return endpoint.transport == .ssh && profile.hasSSHConnection && address == endpoint.host
            && profile.port == endpoint.port && (endpoint.user == nil || endpoint.user == profile.user)
    }
    private func profile(_ id: UUID, endpoint: GitRemoteEndpoint) async throws -> RemoteHostProfile {
        guard let stored = try await hosts.host(id: id) else { throw GitCredentialConfigurationError.configureSSH }
        let value = try RemoteHostProfile(stored: stored)
        guard Self.matches(value, endpoint: endpoint) else { throw GitCredentialConfigurationError.hostMismatch }
        guard value.jumpChain.isEmpty else { throw GitCredentialConfigurationError.unsupportedJump }
        return value
    }
    static func canonicalFingerprint(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("SHA256:") else { throw GitRemoteFailure.invalidHostKey }
        let raw = String(trimmed.dropFirst(7)).replacingOccurrences(of: "=", with: "")
        guard let bytes = Data(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)), bytes.count == 32 else { throw GitRemoteFailure.invalidHostKey }
        return "SHA256:" + bytes.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    static func privateKey(_ bytes: Data, type: SSHAuthMethod.SSHKeyType) throws -> Data {
        if type == .ecdsaP256 {
            // Existing device-generated P256 profiles store raw32 bytes. The
            // native OpenSSL-backed client accepts an in-memory PKCS8 PEM.
            return Data(try P256.Signing.PrivateKey(rawRepresentation: bytes).pemRepresentation.utf8)
        }
        return bytes
    }
    private func resolve(_ endpoint: GitRemoteEndpoint, scope: GitCredentialScope, choice: GitRemoteCredentialChoice, fingerprint: String? = nil) async throws -> Resolved {
        switch choice {
        case .automatic:
            if endpoint.transport == .https {
                if endpoint.host == "github.com", endpoint.port == 443, let token = try github.token() { return .init(authentication: try .https(for: endpoint, username: "x-access-token", password: Data(token.utf8)), profile: nil) }
                return .init(authentication: .anonymous(for: endpoint), profile: nil)
            }
            let options = try await hostOptions(endpoint: endpoint)
            guard options.count == 1, let value = options.first else { throw options.isEmpty ? GitCredentialConfigurationError.configureSSH : .chooseSSHHost }
            return try await resolve(endpoint, scope: scope, choice: .savedSSHHost(id: value.id), fingerprint: fingerprint)
        case .anonymous:
            guard endpoint.transport == .https else { throw GitCredentialConfigurationError.configureSSH }
            return .init(authentication: .anonymous(for: endpoint), profile: nil)
        case .savedToken(let id, let username):
            let handle = CredentialHandle(id: id)
            guard let before = try await vault.metadata(handle), Self.admits(before, endpoint: endpoint, scope: scope) else { throw GitCredentialConfigurationError.selectCredential }
            let bytes = try await vault.resolveForApprovedUse(handle)
            guard try await vault.metadata(handle) == before else { throw GitCredentialConfigurationError.credentialChanged }
            return .init(authentication: try .https(for: endpoint, username: username, password: bytes), profile: nil)
        case .savedSSHHost(let id):
            let value = try await profile(id, endpoint: endpoint)
            let expected: String?
            if case .pinned(let supplied) = value.hostKeyPolicy { expected = try Self.canonicalFingerprint(supplied) }
            else { expected = fingerprint }
            let authentication: GitRemoteAuthentication
            switch value.auth {
            case .none: throw GitCredentialConfigurationError.configureSSH
            case .password(let ref): authentication = try .sshPassword(for: endpoint, username: value.user, password: secret(ref), fingerprintSHA256: expected)
            case .importedKey(let ref, let type), .deviceGeneratedKey(let ref, let type):
                authentication = try .ssh(for: endpoint, username: value.user, privateKey: Self.privateKey(secret(ref), type: type), fingerprintSHA256: expected)
            }
            guard try await profile(id, endpoint: endpoint) == value else { throw GitCredentialConfigurationError.credentialChanged }
            return .init(authentication: authentication, profile: value)
        }
    }
    func withAuthentication<Result: Sendable>(endpoint: GitRemoteEndpoint, scope: GitCredentialScope,
        authorize: @Sendable () async throws -> Void,
        trust: TrustDecision? = nil,
        operation: @Sendable (GitRemoteAuthentication) async throws -> Result) async throws -> Result {
        try await authorize(); try Task.checkCancellation()
        let initialBinding = try binding(endpoint, scope: scope)
        let selected = initialBinding?.choice ?? .automatic
        let first = try await resolve(endpoint, scope: scope, choice: selected)
        try await authorize(); try Task.checkCancellation()
        guard try binding(endpoint, scope: scope) == initialBinding else { throw GitCredentialConfigurationError.credentialChanged }
        do { return try await operation(first.authentication) }
        catch {
            let failure = (error as? GitRemoteFailure) ?? (error as? GitCloneRecoveryError)?.remoteFailure
            guard case .hostKeyNotTrusted(let challenge) = failure, let profile = first.profile,
                  case .trustOnFirstUse = profile.hostKeyPolicy,
                  challenge.host == endpoint.host, challenge.port == endpoint.port, challenge.user == profile.user else { throw error }
            let received = try Self.canonicalFingerprint(challenge.fingerprintSHA256)
            if let known = try await hosts.knownHost(address: profile.address, port: profile.port, keyType: challenge.keyType) {
                let expected = try Self.canonicalFingerprint(known.fingerprintSHA256)
                guard expected == received else { throw GitRemoteFailure.hostKeyChanged(expected: expected, received: received) }
            } else {
                guard let trust else { throw GitCredentialConfigurationError.trustRequired }
                let approved = await trust(.init(hostID: profile.id, address: profile.address, port: profile.port, keyType: challenge.keyType, fingerprintSHA256: received))
                try await authorize(); try Task.checkCancellation()
                guard approved else { throw GitCredentialConfigurationError.trustRequired }
                guard try await self.profile(profile.id, endpoint: endpoint) == profile,
                      try binding(endpoint, scope: scope) == initialBinding else { throw GitCredentialConfigurationError.credentialChanged }
                // A simultaneous connection may have saved a different host
                // key while the real user decision was pending. Never replace it.
                if let now = try await hosts.knownHost(address: profile.address, port: profile.port, keyType: challenge.keyType) {
                    guard try Self.canonicalFingerprint(now.fingerprintSHA256) == received else { throw GitRemoteFailure.hostKeyChanged(expected: now.fingerprintSHA256, received: received) }
                } else {
                    guard try await hosts.trustIfAbsentOrMatching(.init(hostID: profile.id, address: profile.address, port: profile.port, keyType: challenge.keyType, fingerprintSHA256: received)) else {
                        throw GitCredentialConfigurationError.credentialChanged
                    }
                }
            }
            try await authorize(); try Task.checkCancellation()
            guard try binding(endpoint, scope: scope) == initialBinding,
                  try await self.profile(profile.id, endpoint: endpoint) == profile else { throw GitCredentialConfigurationError.credentialChanged }
            let retry = try await resolve(endpoint, scope: scope, choice: .savedSSHHost(id: profile.id), fingerprint: received)
            try await authorize(); try Task.checkCancellation()
            // Exactly one pre-authentication retry. A new challenge, changed
            // key, cancellation, auth or transport error is not looped.
            return try await operation(retry.authentication)
        }
    }
}
