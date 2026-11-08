// FloeExecution — one source of truth for guest-writable /floe/env paths.
//
// Temp uses the resolved environment's disk-backed overlay; caches and final
// installations stay on its persistent shared write layer. The App prepares
// and exports temp at the existing command channel, including for older guest
// runners whose boot default is still /floe/env/tmp. Their old files remain.
//
// Lifecycle: the existing channel prepares scratch in the admitted guest's
// namespace before exec. Existing runner boot preparation still owns caches.
// Scratch follows the project/VM disk lifecycle; this adds no cache deletion
// or background cleanup, and old shared /floe/env/tmp files are preserved.

import Foundation

public enum LinuxGuestWritablePaths {
    /// Root of the persistent environment write layer as seen in the guest.
    public static let root = LinuxGuestMountPoint.environment

    /// Scratch/temp directory. Used for TMPDIR, TMP and TEMP: Python source
    /// builds (e.g. Pillow when no riscv64 wheel exists), gcc/ld intermediate
    /// files and gem native extensions all build here.
    public static let tmp = LinuxGuestProcessEnvironment.scratchDirectory

    /// XDG_CACHE_HOME: generic per-user caches that follow the XDG base-dir
    /// spec (many CLI tools write below ~/.cache).
    public static let xdgCache = root + "/cache/xdg"

    /// PIP_CACHE_DIR: pip's HTTP and wheel cache.
    public static let pipCache = root + "/cache/pip"

    /// npm_config_cache: npm/pnpm's package and tarball cache.
    public static let npmCache = root + "/cache/npm"

    /// The App prepares private disk scratch at command admission. Existing
    /// runner boot preparation owns the cache directories; guest commands run
    /// as root inside their resolved environment namespace.
    public static let bootDirectories: [(path: String, mode: UInt16)] = [
        (tmp, 0o700),
        (xdgCache, 0o755),
        (pipCache, 0o755),
        (npmCache, 0o755)
    ]

    /// The environment variables every guest command inherits once the boot
    /// directories exist. Values are guest-absolute paths; callers may still
    /// override them explicitly.
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
