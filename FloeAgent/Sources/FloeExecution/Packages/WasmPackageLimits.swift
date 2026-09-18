// FloeExecution — bounds for installable WASI command packages.
//
// Small sandboxed utilities and full language interpreters share one runtime,
// so the limits live in the signed catalog as optional per-package metadata.
// Defaults keep every existing package exactly as constrained as before; an
// entry may only widen them within these reviewed ceilings, and a catalog
// entry that exceeds a ceiling is rejected at signature verification time.

import Foundation
import FloeCore

public enum WasmPackageLimits {
    /// Default module ceiling: the historical 4 MiB bound for small utilities.
    public static let defaultModuleMaxBytes = 4 * 1024 * 1024
    /// Hard ceiling for signed interpreter-class packages (measured: Ruby 3.4
    /// wasip1 is 34.7 MiB, PHP 8.2 cgi 13.2 MiB).
    public static let maximumModuleMaxBytes = 64 * 1024 * 1024
    public static let minimumModuleMaxBytes = 64 * 1024

    /// Default linear-memory growth ceiling.
    public static let defaultMemoryMaxBytes = 64 * 1024 * 1024
    public static let maximumMemoryMaxBytes = 1024 * 1024 * 1024
    public static let minimumMemoryMaxBytes = 16 * 1024 * 1024

    /// Default invocation budget. Interpreters may need longer than a utility.
    public static let defaultTimeoutSeconds: TimeInterval = 30
    public static let maximumTimeoutSeconds: TimeInterval = 600
    public static let minimumTimeoutSeconds: TimeInterval = 5

    /// The download closure contract does not carry a per-entry byte budget, so
    /// `SignedWasmCapabilityStore` verifies the artifact against the entry
    /// limit after the transfer. This constant is the transport ceiling a
    /// downloader may use; no signed package can exceed it.
    public static let maximumDownloadBytes = maximumModuleMaxBytes

    static func validateModuleMaxBytes(_ value: Int) throws {
        guard value >= minimumModuleMaxBytes, value <= maximumModuleMaxBytes else {
            throw FloeError.validationFailed("WASM catalog moduleMaxBytes is outside the reviewed range")
        }
    }

    static func validateMemoryMaxBytes(_ value: Int) throws {
        guard value >= minimumMemoryMaxBytes, value <= maximumMemoryMaxBytes else {
            throw FloeError.validationFailed("WASM catalog memoryMaxBytes is outside the reviewed range")
        }
    }

    static func validateTimeoutSeconds(_ value: Int) throws {
        guard TimeInterval(value) >= minimumTimeoutSeconds, TimeInterval(value) <= maximumTimeoutSeconds else {
            throw FloeError.validationFailed("WASM catalog defaultTimeoutSeconds is outside the reviewed range")
        }
    }
}
