// FloeExecution — defaults for processes in the resolved Linux environment.

/// Guest paths only. The mount root comes from native environment resolution,
/// never from a model-provided host path. Caller overrides remain the shell
/// service's responsibility; this is not a filter for explicit process env.
public enum LinuxGuestProcessEnvironment {
    /// Each resolved environment's resident project owns its overlay root
    /// (e + SHA256(environmentID)); this path is on that guest disk, never
    /// the shared 9p write layer or the task's RAM-backed /tmp.
    public static let scratchDirectory = "/var/tmp/floe-runtime"

    public static func defaults(environmentDirectory: String) -> [String: String] {
        let root = environmentDirectory.hasSuffix("/")
            ? String(environmentDirectory.dropLast()) : environmentDirectory
        return [
            "HOME": root + "/home",
            "TMPDIR": scratchDirectory,
            "TMP": scratchDirectory,
            "TEMP": scratchDirectory,
            "TERM": "xterm-256color",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PS1": "[\\w]\\$ "
        ]
        // Do not set PATH here: the Linux backend activates the environment's
        // Python venv and Node prefix before exporting these defaults. A host
        // PATH (or even a new distro-only PATH) would undo that activation.
    }

    /// Used only after the existing Linux channel/namespace owner admits a
    /// run, service or PTY. The wrapper execs the unchanged argv, so stdin,
    /// process ownership, cancellation and the final venv stay unchanged.
    /// Ordinary explicit env/CLI exports run afterward; sensitive env names
    /// must be excluded here because the guest already applied that envp.
    public static func preparedArgv(
        _ argv: [String], excludingTemporaryNames: Set<String> = []
    ) -> [String] {
        guard !argv.isEmpty else { return argv }
        // The existing archive bridge is a runner control request, not an
        // exec-able guest binary. Keep its framing and authority unchanged.
        guard argv.first != "floe-host" else { return argv }
        // Preparation is not an execution veto: even a full/broken guest
        // must retain ordinary repair commands and explicit TMPDIR choices.
        // mkdir's real error remains on stderr; no silent host/tmp fallback.
        let prepare = "if [ ! -L /var/tmp ] && [ ! -L \(scratchDirectory) ]; then mkdir -p -m 700 \(scratchDirectory); else printf '%s\\n' 'Floe temporary directory is a symbolic link' >&2; fi\n"
        let exports = ["TMPDIR", "TMP", "TEMP"].filter { !excludingTemporaryNames.contains($0) }
            .map { "export \($0)='\(scratchDirectory)'\n" }.joined()
        return ["/bin/sh", "-c", prepare + exports + "exec \"$@\"\n", "floe-guest-scratch"] + argv
    }
}
