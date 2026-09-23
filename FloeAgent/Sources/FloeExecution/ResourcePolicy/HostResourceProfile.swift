// FloeExecution — ResourcePolicy: real host family / physical RAM / CPU detect.
//
// SPDX-License-Identifier: MPL-2.0
//
// The default quota depends on the ACTUAL device (family, physical memory,
// CPU count), not a compile-time constant. Detection is factored into small,
// injectable seams so focused tests exercise every bucket without relying on
// the machine they run on. No private identifiers are persisted; the
// unparsed hardware identifier is used only for the iPad Air default and
// diagnostics.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Coarse product family used by the default quota table.
public enum HostProductFamily: String, Sendable, Equatable, Codable {
    case phone
    case pad
    case mac
    case unknown
}

/// One observation of the host Floe runs on.
public struct HostResourceProfile: Sendable, Equatable {
    public var family: HostProductFamily
    /// `ProcessInfo.physicalMemory`: RAM the OS reports for this device.
    public var physicalMemoryBytes: UInt64
    /// `ProcessInfo.activeProcessorCount`: cores available to this process.
    public var activeProcessorCount: Int
    /// `uname` machine identifier ("iPadAir13,2", "iPhone17,1", …), used
    /// only for explicit device defaults and diagnostics.
    public var hardwareIdentifier: String

    public init(
        family: HostProductFamily,
        physicalMemoryBytes: UInt64,
        activeProcessorCount: Int,
        hardwareIdentifier: String
    ) {
        self.family = family
        self.physicalMemoryBytes = physicalMemoryBytes
        self.activeProcessorCount = max(1, activeProcessorCount)
        self.hardwareIdentifier = hardwareIdentifier
    }

    /// Production observation: classifies the current device.
    public static var current: HostResourceProfile {
        HostResourceProfile(
            family: detectFamily(hardwareIdentifier: machineIdentifier),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            hardwareIdentifier: machineIdentifier
        )
    }

    /// The `uname` machine identifier. Empty string on failure; never fatal.
    public static var machineIdentifier: String {
        var system = utsname()
        guard uname(&system) == 0 else { return "" }
        // Copy the tuple out first: reading it through a pointer while the
        // surrounding `system` is still mutably reachable violates Swift's
        // exclusivity rule.
        var machine = system.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(validatingCString: $0) ?? ""
            }
        }
    }

    /// Classifies the family from the UI idiom (when UIKit exists) with a
    /// uname fallback so mac-style hosts do not depend on UIKit availability.
    static func detectFamily(hardwareIdentifier: String) -> HostProductFamily {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: return .phone
        case .pad: return .pad
        case .tv, .carPlay, .vision, .mac, .unspecified: break
        @unknown default: break
        }
        #endif
        if hardwareIdentifier.hasPrefix("iPhone") { return .phone }
        if hardwareIdentifier.hasPrefix("iPad") { return .pad }
        if hardwareIdentifier.hasPrefix("Mac") || hardwareIdentifier == "arm64" { return .mac }
        #if targetEnvironment(simulator)
        // Simulator uname reports the host arch; infer from the idiom above
        // when possible, else fall back to environment hints.
        if let simulated = ProcessInfo.processInfo.environment["SIMDUCT_PRODUCT_TYPE"] {
            if simulated.contains("iPad") { return .pad }
            return .phone
        }
        #endif
        return .unknown
    }

    /// Physical memory bucket used by the quota table. Bucket edges sit at
    /// the midpoint between marketed sizes, which tolerates the rounding of
    /// `physicalMemory` (6/8/12 GB devices never report an exact boundary).
    public enum MemoryBucket: String, Sendable, Equatable {
        case upTo4GB
        case around6GB
        case around8GB
        case around12GB
        case atLeast16GB
    }

    public static func memoryBucket(physicalMemoryBytes bytes: UInt64) -> MemoryBucket {
        let gib: UInt64 = 1024 * 1024 * 1024
        if bytes <= 5 * gib { return .upTo4GB }
        if bytes <= 7 * gib { return .around6GB }
        if bytes <= 10 * gib { return .around8GB }
        if bytes <= 14 * gib { return .around12GB }
        return .atLeast16GB
    }

    public var memoryBucket: MemoryBucket { Self.memoryBucket(physicalMemoryBytes: physicalMemoryBytes) }
}
