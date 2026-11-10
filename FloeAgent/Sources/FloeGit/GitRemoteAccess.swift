// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// A repository address, not an execution command or credential container.
/// Keep SCP spelling for relative-to-home paths; an ssh:// absolute path is
/// deliberately not substituted for user@host:relative/path.
public struct GitRemoteEndpoint: Sendable, Hashable, Codable {
    public enum Transport: String, Sendable, Codable { case https, ssh }
    public let transport: Transport
    public let transportURL: String
    public let host: String
    public let port: Int
    public let user: String?
    public let repositoryPath: String
    public var suggestedDirectoryName: String {
        let name = (repositoryPath as NSString).lastPathComponent
        let trimmed = name.hasSuffix(".git") ? String(name.dropLast(4)) : name
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "Repository" : trimmed
    }
    /// libgit2's SSH URI parser intentionally leaves path percent escapes
    /// untouched before quoting a remote git-upload-pack command. Its native
    /// call therefore needs the decoded path, while UI/storage keep the URI.
    var nativeTransportURL: String {
        guard transport == .ssh, transportURL.contains("://"),
              var authority = URLComponents(string: transportURL) else { return transportURL }
        authority.path = ""; authority.query = nil; authority.fragment = nil
        return (authority.string ?? origin) + repositoryPath
    }
    public var origin: String {
        var c = URLComponents(); c.scheme = transport.rawValue; c.host = host
        if port != (transport == .https ? 443 : 22) { c.port = port }
        return c.string ?? ""
    }
    public init(_ address: String) throws {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8192,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              !value.contains("\\") else { throw GitRemoteFailure.invalidAddress }
        if !value.contains("://") {
            let pattern = #"^(?:([A-Za-z0-9._-]+)@)?(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):(.+)$"#
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(value.startIndex..., in: value)
            guard let m = expression.firstMatch(in: value, range: range) else { throw GitRemoteFailure.invalidAddress }
            func part(_ index: Int) -> String? { Range(m.range(at: index), in: value).map { String(value[$0]) } }
            guard let rawHost = part(2), let path = part(3), !path.isEmpty,
                  !path.contains("?"), !path.contains("#"), path != "/" else { throw GitRemoteFailure.invalidAddress }
            transport = .ssh; transportURL = value; host = Self.canonicalHost(rawHost); port = 22
            user = part(1); repositoryPath = path
        } else {
            // Preserve existing percent escapes when raw Unicode/space occurs in
            // the same address; Foundation otherwise repairs '%' twice.
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%".utf8)
            let encoded = value.utf8.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
            guard let components = URLComponents(string: encoded), let url = components.url,
                  let scheme = components.scheme?.lowercased(), let transport = Transport(rawValue: scheme),
                  let rawHost = url.host, !rawHost.isEmpty,
                  components.password == nil, components.query == nil, components.fragment == nil,
                  transport != .https || components.user == nil,
                  !components.path.isEmpty, components.path != "/",
                  components.path.rangeOfCharacter(from: .controlCharacters) == nil,
                  components.user?.rangeOfCharacter(from: .controlCharacters) == nil else { throw GitRemoteFailure.invalidAddress }
            let port = components.port ?? (transport == .https ? 443 : 22)
            guard (1...65535).contains(port) else { throw GitRemoteFailure.invalidAddress }
            self.transport = transport; transportURL = url.absoluteString
            host = Self.canonicalHost(rawHost); self.port = port; user = components.user; repositoryPath = components.path
        }
        guard !host.isEmpty, !host.hasSuffix("."), !host.contains("%"),
              !repositoryPath.contains("\0"),
              transport != .ssh || (!repositoryPath.contains("'") && !repositoryPath.hasPrefix("-")) else { throw GitRemoteFailure.invalidAddress }
    }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        try self.init(value)
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(transportURL)
    }
    private static func canonicalHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("[") && lower.hasSuffix("]") ? String(lower.dropFirst().dropLast()) : lower
    }
    /// Used by C credential callbacks. Request paths/query may differ during
    /// negotiation, but origin, scheme and SSH identity must remain pinned.
    public func permitsCredentialCallback(_ callback: String, username: String?) -> Bool {
        if transport == .ssh, !callback.contains("://") {
            guard let offered = try? GitRemoteEndpoint(callback), offered.transport == .ssh,
                  offered.host == host, offered.port == port else { return false }
            if let user, let supplied = offered.user ?? username, supplied != user { return false }
            return true
        }
        guard let c = URLComponents(string: callback), let url = c.url, let scheme = c.scheme?.lowercased(),
              scheme == transport.rawValue, let callbackHost = url.host,
              Self.canonicalHost(callbackHost) == host,
              (c.port ?? (transport == .https ? 443 : 22)) == port,
              c.password == nil else { return false }
        if transport == .https { return c.user == nil }
        if let user, let supplied = c.user ?? username, supplied != user { return false }
        return true
    }
}

/// Public host-key challenge only; private key/token bytes never enter models,
/// operation results, logs, repository config or this challenge.
public struct GitSSHHostKeyChallenge: Sendable, Equatable, Codable {
    public let host: String
    public let port: Int
    public let user: String
    public let keyType: String
    public let fingerprintSHA256: String
    public init(host: String, port: Int, user: String, keyType: String, fingerprintSHA256: String) {
        self.host = host; self.port = port; self.user = user; self.keyType = keyType; self.fingerprintSHA256 = fingerprintSHA256
    }
}

/// Resolved in-memory material from existing App credential/host stores. This
/// type is intentionally not Codable and always renders as redacted metadata.
public struct GitRemoteAuthentication: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Material: Sendable {
        case anonymous
        case https(username: String, password: Data)
        case ssh(username: String, privateKey: Data, passphrase: Data?, fingerprint: String?)
        case sshPassword(username: String, password: Data, fingerprint: String?)
    }
    let endpoint: GitRemoteEndpoint
    let material: Material
    public var description: String { "GitRemoteAuthentication(\(endpoint.transport.rawValue), credentials: redacted)" }
    public var debugDescription: String { description }
    public static func anonymous(for endpoint: GitRemoteEndpoint) -> Self {
        Self(endpoint: endpoint, material: .anonymous)
    }
    public static func https(for endpoint: GitRemoteEndpoint, username: String, password: Data) throws -> Self {
        guard endpoint.transport == .https, validUsername(username), validCString(password, maximum: 65_536), !password.isEmpty else { throw GitRemoteFailure.credentialsRequired }
        return Self(endpoint: endpoint, material: .https(username: username, password: password))
    }
    public static func ssh(for endpoint: GitRemoteEndpoint, username: String, privateKey: Data, passphrase: Data? = nil, fingerprintSHA256: String?) throws -> Self {
        guard endpoint.transport == .ssh, validUsername(username), endpoint.user == nil || endpoint.user == username,
              validCString(privateKey, maximum: 128 * 1_024), !privateKey.isEmpty,
              passphrase.map({ validCString($0, maximum: 65_536) }) ?? true else { throw GitRemoteFailure.credentialsRequired }
        try validateFingerprint(fingerprintSHA256)
        return Self(endpoint: endpoint, material: .ssh(username: username, privateKey: privateKey, passphrase: passphrase, fingerprint: fingerprintSHA256))
    }
    public static func sshPassword(for endpoint: GitRemoteEndpoint, username: String, password: Data, fingerprintSHA256: String?) throws -> Self {
        guard endpoint.transport == .ssh, validUsername(username), endpoint.user == nil || endpoint.user == username,
              validCString(password, maximum: 65_536), !password.isEmpty else { throw GitRemoteFailure.credentialsRequired }
        try validateFingerprint(fingerprintSHA256)
        return Self(endpoint: endpoint, material: .sshPassword(username: username, password: password, fingerprint: fingerprintSHA256))
    }
    private static func validateFingerprint(_ fingerprintSHA256: String?) throws {
        if let fingerprintSHA256 {
            guard fingerprintSHA256.hasPrefix("SHA256:"),
                  let decoded = Data(base64Encoded: String(fingerprintSHA256.dropFirst(7)) + String(repeating: "=", count: (4 - fingerprintSHA256.dropFirst(7).count % 4) % 4)), decoded.count == 32 else {
                throw GitRemoteFailure.invalidHostKey
            }
        }
    }
    private static func validUsername(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    private static func validCString(_ value: Data, maximum: Int) -> Bool {
        value.count <= maximum && !value.contains(0) && String(data: value, encoding: .utf8) != nil
    }
}

public struct GitRemoteProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case connecting, receiving, indexing, sending, updatingReferences }
    public let phase: Phase
    public let completedObjects: Int
    public let totalObjects: Int
    public let bytes: Int64
    public init(phase: Phase, completedObjects: Int = 0, totalObjects: Int = 0, bytes: Int64 = 0) {
        self.phase = phase; self.completedObjects = max(0, completedObjects)
        self.totalObjects = max(0, totalObjects); self.bytes = max(0, bytes)
    }
}

public enum GitRemoteFailure: Error, Sendable, LocalizedError, Equatable {
    case invalidAddress, credentialsRequired, credentialHostMismatch, invalidHostKey
    case authenticationRejected, untrustedHTTPSCertificate, remoteRejected
    case hostKeyNotTrusted(GitSSHHostKeyChallenge)
    case hostKeyChanged(expected: String, received: String)
    case nativeSSHUnavailable
    case cancelled
    case remoteOutcomeUnknown
    public var errorDescription: String? {
        let text: (String, String) = switch self {
        case .authenticationRejected: ("仓库身份验证未通过，请检查此主机的凭据。", "Repository authentication failed. Check the credentials for this host.")
        case .untrustedHTTPSCertificate: ("无法验证仓库的安全连接，请检查服务器证书。", "The repository's secure connection could not be verified. Check its server certificate.")
        case .remoteRejected: ("远端未接受这次推送，请刷新状态后重试。", "The remote rejected this push. Refresh its status before retrying.")
        case .invalidAddress: ("请输入不含密码或查询参数的 HTTPS／SSH 仓库地址。", "Enter an HTTPS or SSH repository address without a password or query parameters.")
        case .credentialsRequired: ("请为该仓库主机配置登录凭据后重试。", "Configure credentials for this repository host and retry.")
        case .credentialHostMismatch: ("仓库主机已变化，未发送已保存的凭据。", "The repository host changed. Saved credentials were not sent.")
        case .invalidHostKey: ("主机指纹无效，请重新确认连接。", "The host fingerprint is invalid. Verify the connection again.")
        case .hostKeyNotTrusted: ("请先确认此 SSH 主机的指纹。", "Verify this SSH host's fingerprint first.")
        case .hostKeyChanged: ("SSH 主机指纹已变化，连接已停止。", "The SSH host fingerprint changed. The connection was stopped.")
        case .nativeSSHUnavailable: ("当前安装缺少原生 SSH 传输支持。", "Native SSH transport is unavailable in this installation.")
        case .cancelled: ("已取消传输。", "Transfer cancelled.")
        case .remoteOutcomeUnknown: ("尚无法确认远端结果。请先刷新状态后再继续。", "The remote result is uncertain. Refresh its status before continuing.")
        }
        return FloeL10n.isChinese ? text.0 : text.1
    }
}
