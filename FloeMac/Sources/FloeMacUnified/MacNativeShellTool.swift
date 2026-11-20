// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation
import FloeAgentRuntime
import FloeModels
import FloeTools

struct MacNativeShellTool: AgentTool, MacAgentWorkspaceExecutable {
    enum Access: String, Codable, Sendable { case workspace, host }
    struct Arguments: Codable, Sendable {
        var command: String?
        var script: String?
        var access: Access?
        var cwd: String?
        var timeoutSeconds: Double?
        var maxOutputBytes: Int?
    }

    static let name = "exec.shell"
    static let toolDescription = "Run a native macOS shell command starting in this conversation or project's folder. In standard tasks other user files, network and GUI are blocked by macOS workspace sandboxing. Full Access defaults to the native host; access=workspace explicitly keeps confinement. If work needs files outside this workspace or other host resources, request access=host explicitly. Standard tasks must approve host access; Full Access can run it directly. Do not repeat a partially completed command after a denial. Returns real exit status and combined stdout/stderr."
    static let parametersJSON = #"""
    {"type":"object","properties":{"command":{"type":"string"},"script":{"type":"string","description":"Multiline alternative to command"},"access":{"type":"string","enum":["workspace","host"]},"cwd":{"type":"string","description":"Optional working directory relative to the current task root"},"timeoutSeconds":{"type":"number","minimum":0.1,"maximum":600},"maxOutputBytes":{"type":"integer","minimum":256,"maximum":65536}},"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.executesLocalCode, .writesFiles]
    static let isSideEffecting = true
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    static let sandbox = "/usr/bin/sandbox-exec"
    let root: MacAgentWorkspaceRoot

    enum ShellError: LocalizedError {
        case invalid, scope, sandbox, spawn(Int32), read
        var errorDescription: String? {
            switch self {
            case .invalid: "Invalid command, working directory or output limit."
            case .scope: "This command needs a valid approval for the selected Mac access scope."
            case .sandbox: "Workspace isolation is unavailable on this Mac."
            case .spawn(let code): "Could not start the Mac command: " + String(cString: strerror(code))
            case .read: "The Mac command output was interrupted."
            }
        }
    }

    func validate(_ args: Arguments) throws {
        guard (args.command == nil) != (args.script == nil),
              let command = args.command ?? args.script, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= 65_536, !command.utf8.contains(0),
              (0.1...600).contains(args.timeoutSeconds ?? 120),
              (256...65_536).contains(args.maxOutputBytes ?? 16_384) else { throw ShellError.invalid }
        if let cwd = args.cwd, cwd != "." {
            guard cwd == (try? MacAgentWorkspacePinSupport.standardizedRelativePath(cwd)) else { throw ShellError.invalid }
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard case .local = context.scope, context.approvalGrantID != nil, context.approvalOrigin != nil,
              context.allowedWorkspacePaths.isEmpty,
              let physical = root.physicalPath,
              let contextRoot = context.workspaceRootURL,
              MacAgentWorkspacePinSupport.physicalPath(contextRoot.path) == physical else { throw ShellError.scope }
        let access = args.access ?? (context.approvalOrigin == .policy("full-access") ? .host : .workspace)
        if access == .host {
            switch context.approvalOrigin {
            case .humanCard, .policy("full-access"): break
            default: throw ShellError.scope
            }
        } else if !FileManager.default.isExecutableFile(atPath: Self.sandbox) { throw ShellError.sandbox }

        return try await Task.detached(priority: .userInitiated) {
            let cwd = args.cwd ?? "."
            // Pin the working directory rather than using a path-based chdir after approval.
            let probe = cwd == "." ? ".floe-cwd-pin" : cwd + "/.floe-cwd-pin"
            return try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: probe, root: root) { pin in
                try invoke(args, access: access, context: context, workingFD: pin.parentFileDescriptor, workspace: physical)
            }
        }.value
    }

    // A separate app-owned temporary directory per command avoids granting access to the user's global temp files.
    private static let profile = """
    (version 1)
    (deny default)
    (allow process-fork process-exec sysctl-read)
    (allow signal (target self) (target children))
    (allow file-read* file-map-executable (subpath "/System") (subpath "/bin") (subpath "/sbin")
      (subpath "/usr/bin") (subpath "/usr/sbin") (subpath "/usr/lib") (subpath "/usr/libexec")
      (subpath "/usr/share") (literal "/dev/null") (literal "/dev/urandom")
      (literal "/dev/random") (literal "/dev/zero") (literal "/private/var/select/sh") (literal "/private/etc/localtime"))
    (deny file-read* file-map-executable (subpath "/System/Volumes"))
    \(FileManager.default.fileExists(atPath: "/System/Library/Sandbox/Profiles/dyld-support.sb") ? #"(import "dyld-support.sb")"# : #"(allow file-read* (literal "/"))"#)
    (allow file-read* (subpath "/System/Volumes/Preboot/Cryptexes/OS/usr/lib")
      (subpath "/System/Volumes/Preboot/Cryptexes/OS/System/Library"))
    (allow file-read-metadata (literal "/") (literal "/usr") (literal "/dev") (literal "/private"))
    (allow file-write-data (literal "/dev/null"))
    (allow file-read* file-write* (subpath (param "WORKSPACE")) (subpath (param "TEMP")))
    """

    private func invoke(_ args: Arguments, access: Access, context: ToolContext, workingFD: Int32, workspace: String) throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        var scratch = Array((NSTemporaryDirectory() + "/floe-command.XXXXXX").utf8CString)
        guard mkdtemp(&scratch) != nil else { throw ShellError.sandbox }
        let temporary = URL(fileURLWithPath: String(cString: scratch)).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let host = access == .host
        let shell = ["/bin/sh", "-c", args.command ?? args.script ?? ""]
        let command = host ? shell : [Self.sandbox, "-D", "WORKSPACE=" + workspace, "-D", "TEMP=" + temporary.path, "-p", Self.profile] + shell
        let path = host ? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" : "/usr/bin:/bin:/usr/sbin:/sbin"
        let environment = ["PATH=" + path, "HOME=" + (host ? NSHomeDirectory() : temporary.path),
                           "TMPDIR=" + temporary.path + "/", "LANG=en_US.UTF-8"]
        var output = [Int32](repeating: -1, count: 2)
        guard pipe(&output) == 0 else { throw ShellError.spawn(errno) }
        defer { close(output[0]); if output[1] >= 0 { close(output[1]) } }
        var actions: posix_spawn_file_actions_t?, attrs: posix_spawnattr_t?
        func check(_ code: Int32) throws { if code != 0 { throw ShellError.spawn(code) } }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attrs))
        defer { posix_spawnattr_destroy(&attrs) }
        try check(posix_spawn_file_actions_addfchdir_np(&actions, workingFD))
        try check(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, output[1], STDERR_FILENO))
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask)
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaults, signal) }
        try check(posix_spawnattr_setsigmask(&attrs, &mask))
        try check(posix_spawnattr_setsigdefault(&attrs, &defaults))
        try check(posix_spawnattr_setpgroup(&attrs, 0))
        try check(posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        var argv = command.map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, command[0], &actions, &attrs, &argv, &envp))
        close(output[1]); output[1] = -1
        var status: Int32 = 0, reaped = false
        defer {
            if !reaped {
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
        }
        let until = ContinuousClock.now + .milliseconds(Int64((args.timeoutSeconds ?? 120) * 1000))
        let cap = args.maxOutputBytes ?? 16_384
        var bytes = Data(), truncated = false, timedOut = false, eof = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Keep the leader unreaped until its group has been stopped, so pid/pgid cannot be recycled.
        while !eof {
            try context.cancellation.throwIfCancelled()
            if ContinuousClock.now >= until { timedOut = true; break }
            var item = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
            let available = Darwin.poll(&item, 1, 75)
            if available == 0 || (available < 0 && errno == EINTR) { continue }
            guard available > 0 else { throw ShellError.read }
            let n = Darwin.read(output[0], &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw ShellError.read }
            if n == 0 { eof = true; continue }
            let keep = min(cap - bytes.count, n)
            bytes.append(contentsOf: buffer.prefix(keep))
            truncated = truncated || keep < n
        }
        // A command may close its output and keep running. Continue observing cancellation and its deadline.
        while !timedOut {
            try context.cancellation.throwIfCancelled()
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid { break }
            if ContinuousClock.now >= until { timedOut = true; break }
            usleep(20_000)
        }
        kill(-pid, SIGKILL)
        while waitpid(pid, &status, 0) == -1 { if errno != EINTR { throw ShellError.read } }
        reaped = true
        let code: Int32 = timedOut ? 124 : (status & 127 == 0 ? (status >> 8) & 255 : 128 + (status & 127))
        let body = String(decoding: bytes, as: UTF8.self)
        let note = timedOut ? " (timed out)" : ""
        var outputText = "exit=\(code)\(note)\n" + body + (truncated ? "\n[output truncated]" : "")
        if !host && code != 0 && (body.contains("Operation not permitted") || body.contains("Permission denied")) {
            outputText += "\nThe workspace boundary may have blocked this operation. For resources outside it request access=host, and check for partial changes before retrying."
        }
        return .init(digesting: outputText, exitStatus: code, maximumSummaryCharacters: cap + 80,
                     capturedOutput: outputText, capturedOutputTruncated: truncated, outcomeUnknown: timedOut)
    }
}
