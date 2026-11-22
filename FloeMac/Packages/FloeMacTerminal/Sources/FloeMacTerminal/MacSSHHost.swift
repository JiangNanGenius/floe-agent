// FloeMacTerminal — validated user-supplied SSH destination.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A user-supplied SSH destination, validated before any process launch.
///
/// The Mac app has no saved host registry (unlike the iPad RemoteSession
/// center), so the fallback contract is the installed OpenSSH client run
/// interactively: the terminal shows the system host-key and credential
/// prompts and the user answers them directly. This type is the only input
/// surface for that launch; it rejects malformed destinations so invalid
/// input never reaches the child process.
///
/// Security properties:
/// - The destination is passed to `ssh` as a single argv element; no shell
///   is involved at any point, so no string interpolation or escaping rules
///   can be bypassed.
/// - No option that weakens host-key verification (e.g.
///   `StrictHostKeyChecking=no`/`accept-new`) is ever added; ssh keeps its
///   compiled-in defaults and asks the user on a new or changed key.
/// - Passwords and passphrases are typed by the user into the on-screen
///   terminal only; nothing here reads, stores or exposes them.
public struct MacSSHHost: Equatable, Sendable {

    /// Optional remote login name (`user@host` when set).
    public let user: String?

    /// Bare hostname, IPv4 address, or bracketed IPv6 address.
    public let host: String

    /// Optional TCP port (1...65535). nil means ssh's default (22).
    public let port: Int?

    /// The ssh destination string (`user@host` or `host`).
    public var destination: String {
        switch user {
        case .some(let user): return "\(user)@\(host)"
        case .none: return host
        }
    }

    private init(user: String?, host: String, port: Int?) {
        self.user = user
        self.host = host
        self.port = port
    }

    /// Validates raw user input and returns the destination.
    /// - Throws: ``MacSSHHostValidationError`` for empty, malformed or
    ///   unsafe input. Validation is strict on purpose: anything that is
    ///   not a plain hostname/address is rejected rather than repaired.
    public static func validated(host: String, user: String? = nil, port: Int? = nil) throws -> MacSSHHost {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw MacSSHHostValidationError.emptyHost }
        guard trimmedHost.count <= 253 else { throw MacSSHHostValidationError.invalidHost(trimmedHost) }
        guard Self.isValidHost(trimmedHost) else { throw MacSSHHostValidationError.invalidHost(trimmedHost) }

        let trimmedUser = user?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser: String?
        switch trimmedUser {
        case .none, .some(""):
            cleanUser = nil
        case .some(let value):
            guard Self.isValidUser(value) else { throw MacSSHHostValidationError.invalidUser(value) }
            cleanUser = value
        }

        if let port {
            guard (1...65535).contains(port) else {
                throw MacSSHHostValidationError.invalidPort(port)
            }
        }

        return MacSSHHost(user: cleanUser, host: trimmedHost, port: port)
    }

    /// Builds the exact argv handed to the ssh executable. Single elements
    /// only; the destination is never split or reparsed.
    public func argv() -> [String] {
        var args = ["-tt"]
        if let port {
            args.append("-p")
            args.append(String(port))
        }
        args.append(contentsOf: ["--", destination])
        return args
    }

    /// Host grammar: dot-separated labels of ASCII alphanumerics and `-`,
    /// a bracketed IPv6 address, or a plain IPv4 address. Notably this
    /// rejects whitespace, `@`, `:user` suffixes, path separators, quotes
    /// and every shell metacharacter, so a pasted string cannot smuggle in
    /// extra ssh options or a remote command.
    private static func isValidHost(_ host: String) -> Bool {
        if host.hasPrefix("[") {
            // Bracketed IPv6: hex digits, colons, optional zone-less form.
            guard host.hasSuffix("]"), host.count > 2 else { return false }
            let inner = host.dropFirst().dropLast()
            return inner.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") }
                && inner.contains(":")
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63, label.first != "-", label.last != "-" else { return false }
            for character in label {
                guard character.isASCII, character.isLetter || character.isNumber || character == "-" else {
                    return false
                }
            }
        }
        return true
    }

    /// Login names: no whitespace, no `@`/`:` separators, no path or
    /// quote characters. Non-ASCII names are allowed (real accounts can
    /// have them); structure-breaking characters are not.
    private static func isValidUser(_ user: String) -> Bool {
        guard !user.isEmpty, user.count <= 32 else { return false }
        guard user.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        return user.allSatisfy { character in
            guard !character.isWhitespace else { return false }
            guard !["@", ":", "/", "\\", "\"", "'", "`", "$", "~", "%", "#"].contains(character) else { return false }
            return true
        }
    }
}

public enum MacSSHHostValidationError: Error, Equatable, Sendable {
    case emptyHost
    case invalidHost(String)
    case invalidUser(String)
    case invalidPort(Int)

    public var message: String {
        switch self {
        case .emptyHost:
            return MacTerminalCopy.t("请填写主机地址。", "Enter a host address.")
        case .invalidHost(let host):
            return MacTerminalCopy.t("主机地址无效：\(host)", "Invalid host address: \(host)")
        case .invalidUser(let user):
            return MacTerminalCopy.t("用户名无效：\(user)", "Invalid user name: \(user)")
        case .invalidPort(let port):
            return MacTerminalCopy.t("端口无效：\(port)", "Invalid port: \(port)")
        }
    }
}
