// FloeCore — process-wide memory reservations held by in-process runtimes.
//
// SPDX-License-Identifier: MPL-2.0
//
// Some Floe runtimes reserve memory outside their own allocator bookkeeping:
// the TinyEMU Linux guest runs inside the app process with a fixed RAM budget
// (LinuxGuestLimits), and a local MLX model maps several gigabytes of weights.
// `os_proc_available_memory()` reports whatever the OS currently allows, which
// only reflects the guest *after* it has touched its pages and does not tell a
// load preflight how much the guest is allowed to grow into. The two must not
// be admitted as if the other did not exist.
//
// This registry is the small, dependency-appropriate bridge: FloeExecution
// publishes the guest budget it has admitted, and FloeLocalModelCatalog
// subtracts it when it decides whether a model can load. It is deliberately a
// process-wide value with a lock, not a singleton service: reservations are
// keyed by owner id, setting the same id twice replaces the value (never
// double-counts), and a missing/zero registry keeps the previous behavior.

import Foundation

public enum ResidentMemoryReservations {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reservations: [String: Int64] = [:]

    /// Replaces the reservation for `id` with `bytes` (0 removes it). Called
    /// when a runtime's admission changes, so repeated starts never stack.
    public static func set(id: String, bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if bytes <= 0 {
            reservations.removeValue(forKey: id)
        } else {
            reservations[id] = bytes
        }
    }

    /// Removes the reservation for `id`.
    public static func clear(id: String) {
        set(id: id, bytes: 0)
    }

    /// Total reserved bytes across every registered runtime.
    public static func totalBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return reservations.values.reduce(0, +)
    }

    /// Removes every reservation. Test seam only; production code clears by id.
    public static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        reservations.removeAll()
    }

    public static func reservedBytes(id: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return reservations[id] ?? 0
    }
}
