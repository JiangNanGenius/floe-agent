import Foundation

enum RuntimeProcessHeadroom {
    /// Bytes one admission requires from the process headroom probe: the
    /// guest's RAM plus the fixed per-VM host overhead plus the future
    /// reserve margin. Shared by pool admission/reshape validation and the
    /// machine's last-boundary re-check so one guest is never measured with
    /// two different formulas.
    static func requiredBytes(guestRAMMiB: Int, hostOverheadMiB: Int, futureReserveMiB: Int) -> Int {
        (max(0, guestRAMMiB) + max(0, hostOverheadMiB) + max(0, futureReserveMiB)) * 1_048_576
    }

    /// Bytes the OS estimates the app may still allocate; nil when the API
    /// is unavailable (the platform does not implement it, e.g. macOS). This
    /// reflects RESIDENT charges (guest pages only once touched), which is
    /// why the pool combines it with the quota's not-yet-fulfilled lease
    /// accounting instead of using either alone.
    ///
    /// A raw 0 is a REAL reading on a device: `os_proc_available_memory()`
    /// returns 0 when the process is at/over its dirty-memory limit (or is
    /// not an app), which is exactly when a new guest must be refused. It is
    /// returned as 0, never folded into nil ("probe unavailable"), so the
    /// gates that treat nil as "skip" cannot let a start through at zero
    /// headroom (D1).
    ///
    /// The SIMULATOR is the exception: its app process has no real
    /// dirty-memory accounting and this probe was measured to report a
    /// constant 0 (the same probe records `memAvailableMB=0` in the Office
    /// stage traces). A raw 0 there is not pressure, and treating it as such
    /// queued every guest start until `RuntimeV2Error.queueTimedOut(600)`
    /// with zero emulation time. The simulator therefore reports the probe as
    /// unavailable (nil), leaving the pool quota and pressure gates as the
    /// bound; device semantics are unchanged.
    static func availableBytes() -> Int? {
        #if os(iOS) || os(tvOS) || os(watchOS)
        #if targetEnvironment(simulator)
        return nil
        #else
        if #available(iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            return Int(clamping: os_proc_available_memory())
        }
        return nil
        #endif
        #else
        return nil
        #endif
    }
}
