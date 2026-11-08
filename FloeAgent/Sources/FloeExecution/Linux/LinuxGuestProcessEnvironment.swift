// FloeExecution — defaults for processes in the resolved Linux environment.

/// Guest paths only. The mount root comes from native environment resolution,
/// never from a model-provided host path. Caller overrides remain the shell
/// service's responsibility; this is not a filter for explicit process env.
public enum LinuxGuestProcessEnvironment {
    public static func defaults(environmentDirectory: String) -> [String: String] {
        let root = environmentDirectory.hasSuffix("/")
            ? String(environmentDirectory.dropLast()) : environmentDirectory
        return [
            "HOME": root + "/home",
            "TMPDIR": root + "/tmp",
            "TMP": root + "/tmp",
            "TEMP": root + "/tmp",
            "TERM": "xterm-256color",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PS1": "[\\w]\\$ "
        ]
        // Do not set PATH here: the Linux backend activates the environment's
        // Python venv and Node prefix before exporting these defaults. A host
        // PATH (or even a new distro-only PATH) would undo that activation.
    }
}
