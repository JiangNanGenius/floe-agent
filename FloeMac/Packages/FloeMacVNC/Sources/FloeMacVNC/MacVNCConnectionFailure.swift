// SPDX-License-Identifier: MPL-2.0
//
// Stable, machine-readable VNC failure surface shared by the tool view and
// any toolbox coordinator. Values are secret-free: host/port identify the
/// endpoint the person configured, never credentials.

import Foundation

public enum MacVNCFailureCategory: String, Codable, Sendable, Hashable {
    case credentialMissing
    case authenticationFailed
    case networkUnreachable
    case connectionRefused
    case timedOut
    case handshakeFailed
    case protocolIncompatible
}

public enum MacVNCFailureStage: String, Codable, Sendable, Hashable {
    case configuration
    case credentialResolution
    case transport
    case authentication
    case handshake
    case framebuffer
}

public struct MacVNCConnectionFailure: Error, Codable, Sendable, Hashable {
    public var category: MacVNCFailureCategory
    public var stage: MacVNCFailureStage
    public var retryable: Bool
    public var host: String
    public var port: Int
    public var message: String
    public var underlyingCode: String?

    public init(
        category: MacVNCFailureCategory,
        stage: MacVNCFailureStage,
        retryable: Bool,
        host: String,
        port: Int,
        message: String,
        underlyingCode: String? = nil
    ) {
        self.category = category
        self.stage = stage
        self.retryable = retryable
        self.host = host
        self.port = port
        self.message = message
        self.underlyingCode = underlyingCode
    }
}

extension MacVNCConnectionFailure {
    /// RoyalVNCKit reports transport failures as NSError values. Map them to
    /// actionable, secret-free reasons so the UI and coordinator can
    /// distinguish a rejected password from an unreachable host or timeout.
    static func normalized(
        _ error: Error,
        host: String,
        port: Int,
        passwordConfigured: Bool
    ) -> MacVNCConnectionFailure {
        let nsError = error as NSError
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = "\(raw) \(nsError.domain) \(nsError.code)".lowercased()
        let code = "\(nsError.domain):\(nsError.code)"
        if probe.contains("auth") || probe.contains("password") || probe.contains("security") {
            if passwordConfigured {
                return MacVNCConnectionFailure(
                    category: .authenticationFailed,
                    stage: .authentication,
                    retryable: false,
                    host: host,
                    port: port,
                    message: "VNC authentication was rejected. The password may be incorrect or the server may require a different security type.",
                    underlyingCode: code
                )
            }
            return MacVNCConnectionFailure(
                category: .credentialMissing,
                stage: .credentialResolution,
                retryable: false,
                host: host,
                port: port,
                message: "VNC authentication requires a password, but this connection has no password.",
                underlyingCode: code
            )
        }
        if probe.contains("timed out") || probe.contains("timeout") {
            return MacVNCConnectionFailure(
                category: .timedOut, stage: .transport, retryable: true,
                host: host, port: port,
                message: "VNC connection timed out before the server completed the handshake.",
                underlyingCode: code
            )
        }
        if probe.contains("refused") {
            return MacVNCConnectionFailure(
                category: .connectionRefused, stage: .transport, retryable: true,
                host: host, port: port,
                message: "VNC connection was refused. Confirm the server is listening on the configured host and port.",
                underlyingCode: code
            )
        }
        if probe.contains("unreachable") || probe.contains("no route") {
            return MacVNCConnectionFailure(
                category: .networkUnreachable, stage: .transport, retryable: true,
                host: host, port: port,
                message: "VNC host is unreachable from this Mac. Check the route, VPN, firewall, and address.",
                underlyingCode: code
            )
        }
        if probe.contains("name or service") || probe.contains("dns") || probe.contains("not known") {
            return MacVNCConnectionFailure(
                category: .networkUnreachable, stage: .transport, retryable: true,
                host: host, port: port,
                message: "VNC host name could not be resolved.",
                underlyingCode: code
            )
        }
        if probe.contains("version") || probe.contains("encoding") || probe.contains("protocol") {
            return MacVNCConnectionFailure(
                category: .protocolIncompatible, stage: .handshake, retryable: false,
                host: host, port: port,
                message: "The VNC server uses a protocol or security mode this client does not support.",
                underlyingCode: code
            )
        }
        let detail = raw.isEmpty ? "Unknown transport error" : String(raw.prefix(240))
        return MacVNCConnectionFailure(
            category: .handshakeFailed, stage: .handshake, retryable: true,
            host: host, port: port,
            message: "VNC handshake failed: \(detail) [\(code)].",
            underlyingCode: code
        )
    }
}
