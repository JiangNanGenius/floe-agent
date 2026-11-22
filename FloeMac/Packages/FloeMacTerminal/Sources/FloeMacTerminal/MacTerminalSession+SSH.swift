// FloeMacTerminal — interactive OpenSSH launch for a validated destination.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation

extension MacTerminalSession {

    /// Starts an interactive OpenSSH session to a validated destination.
    ///
    /// This is the fallback SSH path for hosts the user types in directly
    /// (there is no saved-host registry on Mac). It launches the installed
    /// `ssh` client in the session's PTY with `-tt` so the system host-key
    /// confirmation and password/passphrase prompts render in the on-screen
    /// terminal and are answered by the user. No host-key bypass option is
    /// passed; no credential is read or stored by the app.
    ///
    /// - Parameter host: a ``MacSSHHost`` from ``MacSSHHost/validated(host:user:port:)``.
    ///   Never build one from unvalidated strings.
    /// - Parameter scope: working directory the ssh client process starts
    ///   in locally (the remote side always starts in the remote login
    ///   directory).
    /// - Throws: ``MacTerminalScopeError`` when no ssh executable is found,
    ///   or the underlying start failure.
    public func startSSH(_ host: MacSSHHost, scope: MacTerminalScope = .home) throws {
        guard let executable = Self.resolvedSSHExecutable() else {
            throw MacTerminalScopeError.notADirectory("/usr/bin/ssh")
        }
        try start(
            executable: executable,
            arguments: host.argv(),
            workingDirectory: scope.path
        )
    }

    /// The installed OpenSSH client, preferring the system one. Looked up by
    /// path only — never through a shell.
    static func resolvedSSHExecutable() -> String? {
        [
            "/usr/bin/ssh",
            "/usr/local/bin/ssh",
            "/opt/homebrew/bin/ssh",
            "/bin/ssh",
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
