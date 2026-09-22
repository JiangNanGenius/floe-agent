// FloeExecution — one source of truth for guest-writable /floe/env paths.
//
// Every Linux guest command inherits environment variables that point temp
// and cache locations at the persistent environment layer instead of the
// guest's RAM-backed root partition (/tmp is a small tmpfs and the root
// filesystem is compact by design). This enum is the Swift authority for
// those paths; the matching C definitions live in the runner
// (LinuxGuest/runner/floe_exec.c) and must stay aligned — a comment there
// points back here.
//
// Lifecycle: the guest runner creates each directory (with the mode below)
// at boot, so native apt/pip/npm/gem work without per-tool configuration.
// Nothing here is ever deleted automatically: caches survive a guest
// restart and are user data Floe does not garbage-collect.

import Foundation

public enum LinuxGuestWritablePaths {
    /// Root of the persistent environment write layer as seen in the guest.
    public static let root = LinuxGuestMountPoint.environment

    /// Scratch/temp directory. Used for TMPDIR, TMP and TEMP: Python source
    /// builds (e.g. Pillow when no riscv64 wheel exists), gcc/ld intermediate
    /// files and gem native extensions all build here.
    public static let tmp = root + "/tmp"

    /// XDG_CACHE_HOME: generic per-user caches that follow the XDG base-dir
    /// spec (many CLI tools write below ~/.cache).
    public static let xdgCache = root + "/cache/xdg"

    /// PIP_CACHE_DIR: pip's HTTP and wheel cache.
    public static let pipCache = root + "/cache/pip"

    /// npm_config_cache: npm/pnpm's package and tarball cache.
    public static let npmCache = root + "/cache/npm"

    /// Directory the runner prepares at boot with its POSIX mode. `tmp` is a
    /// world-writable sticky directory; cache dirs are root-owned but writable
    /// (the guest runs its commands as root inside the VM).
    public static let bootDirectories: [(path: String, mode: UInt16)] = [
        (tmp, 0o1777),
        (xdgCache, 0o755),
        (pipCache, 0o755),
        (npmCache, 0o755)
    ]

    /// The environment variables every guest command inherits once the boot
    /// directories exist. Values are guest-absolute paths inside the
    /// environment share; callers may still override them explicitly.
    public static func environmentVariables() -> [String: String] {
        [
            "TMPDIR": tmp,
            "TMP": tmp,
            "TEMP": tmp,
            "XDG_CACHE_HOME": xdgCache,
            "PIP_CACHE_DIR": pipCache,
            "npm_config_cache": npmCache
        ]
    }
}
