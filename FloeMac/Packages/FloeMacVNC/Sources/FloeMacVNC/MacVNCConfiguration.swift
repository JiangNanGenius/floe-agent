// SPDX-License-Identifier: MPL-2.0
//
// User-configured VNC endpoint. Secrets stay in memory: the password is
// never written to logs, URLs, descriptions, or persistent storage.

import Foundation

public enum MacVNCValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyHost
    case invalidHost(String)
    case invalidPort(Int)
    case connectionActive
    case ownerDrained

    public var description: String {
        switch self {
        case .emptyHost:
            "VNC host is empty."
        case .invalidHost(let reason):
            "VNC host is invalid: \(reason)"
        case .invalidPort(let port):
            "VNC port \(port) is outside 1...65535."
        case .connectionActive:
            "A VNC connection is already active; close it before connecting again."
        case .ownerDrained:
            "This VNC session owner was drained and cannot open new connections."
        }
    }
}

/// Explicit, user-configured VNC endpoint. Constructing one grants no access;
/// a connection only starts through `MacVNCSessionOwner.connect(using:)`,
/// which a person triggers manually in the tool view.
public struct MacVNCConfiguration: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var password: String?

    public init(host: String, port: Int = 5900, password: String? = nil) {
        self.host = host
        self.port = port
        self.password = password
    }

    /// Applies host/port safety rules. DNS resolution and reachability are
    /// deliberately left to the transport so failures normalize into
    /// actionable, secret-free `MacVNCConnectionFailure` values instead of
    /// ambiguous validation errors.
    public func validated() throws -> MacVNCConfiguration {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw MacVNCValidationError.emptyHost }
        guard !trimmedHost.contains("://") else {
            throw MacVNCValidationError.invalidHost("enter a host name or address, not a URL scheme")
        }
        guard !trimmedHost.contains(where: { $0.isWhitespace }) else {
            throw MacVNCValidationError.invalidHost("host must not contain whitespace")
        }
        guard !trimmedHost.contains("/") && !trimmedHost.contains("?") &&
              !trimmedHost.contains("#") && !trimmedHost.contains("@") else {
            throw MacVNCValidationError.invalidHost("host must not contain path, query, fragment, or credential separators")
        }
        guard (1...65_535).contains(port) else {
            throw MacVNCValidationError.invalidPort(port)
        }
        return MacVNCConfiguration(host: trimmedHost, port: port, password: password)
    }

    /// Secret-free single-line summary safe for diagnostics.
    public var redactedDescription: String {
        "\(host):\(port) password=\(password?.isEmpty == false ? "set" : "none")"
    }
}

extension MacVNCConfiguration: CustomStringConvertible {
    public var description: String { redactedDescription }
}

extension MacVNCConfiguration: CustomDebugStringConvertible {
    public var debugDescription: String { redactedDescription }
}
