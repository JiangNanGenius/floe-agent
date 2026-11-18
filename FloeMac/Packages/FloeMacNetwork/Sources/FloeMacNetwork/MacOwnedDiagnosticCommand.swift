// SPDX-License-Identifier: MPL-2.0

import Darwin
import FloeToolboxCore
import Foundation

/// Owns one fixed system utility and reaps it before returning to the panel.
/// The operation never invokes a shell or inherits the app's environment.
enum MacOwnedDiagnosticCommand {
    struct Result: Sendable {
        let succeeded: Bool
        let output: String
    }

    enum Utility: String {
        case ping = "/sbin/ping"
        case traceroute = "/usr/sbin/traceroute"
        case dns = "/usr/bin/dig"
        case tcp = "/usr/bin/nc"
    }

    static func validateHost(_ host: String) throws {
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
              host.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                      || [45, 46, 58, 95].contains($0)
              }) else { throw ToolboxError.invalid("host name") }
    }

    static func run(_ utility: Utility, arguments: [String], timeout: Duration,
                    gate: MacManualNetworkGate,
                    onStart: (@Sendable (pid_t) -> Void)? = nil) async throws -> Result {
        try Task.checkCancellation()
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw Failure.system(errno) }
        let input = descriptors[0], output = descriptors[1]
        var outputOpen = true
        defer {
            Darwin.close(input)
            if outputOpen { Darwin.close(output) }
        }
        guard fcntl(input, F_SETFD, FD_CLOEXEC) == 0, fcntl(output, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(input, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.system(errno) }

        let pid = try gate.withAdmission {
            try spawn(utility.rawValue, arguments: arguments, output: output)
        }
        Darwin.close(output)
        outputOpen = false
        var owned = true
        defer {
            // Only an unreaped child can reach this path. Its PID is still
            // reserved even if it exited just before the signal.
            if owned {
                _ = kill(pid, SIGKILL)
                while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
            }
        }
        onStart?(pid)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var endOfOutput = false
        var status: Int32 = 0
        let deadline = ContinuousClock.now + timeout
        repeat {
            try Task.checkCancellation()
            guard gate.isOpen() else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            if !endOfOutput {
                let count = Darwin.read(input, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= 65_536 else { throw Failure.outputLimit }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    endOfOutput = true
                } else if errno != EAGAIN && errno != EINTR {
                    throw Failure.system(errno)
                }
            }
            if owned {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid {
                    owned = false
                } else if waited < 0 && errno != EINTR {
                    let code = errno
                    if code == ECHILD { owned = false }
                    throw Failure.system(code)
                }
            }
            if owned || !endOfOutput { try await Task.sleep(for: .milliseconds(20)) }
        } while owned || !endOfOutput
        try Task.checkCancellation()
        guard gate.isOpen() else { throw CancellationError() }
        return Result(succeeded: status == 0, output: String(decoding: data, as: UTF8.self))
    }

    private static func spawn(_ executable: String, arguments: [String], output: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO))

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: POSIX_SPAWN_CLOEXEC_DEFAULT)))
        // The platform dig reads .digrc. Its home is a root-owned empty system
        // directory so a configuration file cannot change the requested operation.
        let environmentStrings = ["LC_ALL=C", "HOME=/var/empty"]
        var environment = environmentStrings.map { value in value.withCString { strdup($0) } }
        var values = ([executable] + arguments).map { value in value.withCString { strdup($0) } }
        defer { (values + environment).forEach { free($0) } }
        guard values.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else {
            throw Failure.system(ENOMEM)
        }
        values.append(nil)
        environment.append(nil)
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable, &actions, &attributes, &values, &environment))
        return pid
    }

    private static func check(_ code: Int32) throws {
        if code != 0 { throw Failure.system(code) }
    }

    private enum Failure: Error {
        case system(Int32), timeout, outputLimit
    }
}
