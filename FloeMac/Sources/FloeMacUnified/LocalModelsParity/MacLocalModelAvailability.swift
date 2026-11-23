// FloeMacUnified LocalModelsParity — Mac runtime availability.
//
// SPDX-License-Identifier: MPL-2.0
//
// Native probe for the platform capabilities the shared local-model runtime
// needs on macOS. The shared FloeLocalModelCatalog/FloeLocalModels modules are
// platform-neutral; this file is the Mac-only adapter that reports honest
// unavailability (Intel Macs, macOS before 15.4, no Metal device) instead of
// letting the MLX stack abort inside libc++.

import Foundation
import Metal
import FloeCore
import FloeLocalModelCatalog

public enum MacLocalModelEngine: String, Sendable, Codable, Equatable {
    case mlx
}

public struct MacLocalModelRuntimeSupport: Sendable, Equatable {
    public var isSupported: Bool
    public var engine: MacLocalModelEngine?
    /// User-actionable reason when `isSupported` is false.
    public var unavailableReason: String?
    /// Effective headroom for local weights on this Mac.
    public var headroomBytes: UInt64
    /// macOS build required by the shared MLX engine (matches the
    /// `@available(macOS 15.4, *)` annotation on the shared engine types).
    public static let requiredMacOSVersion = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)

    public init(
        isSupported: Bool,
        engine: MacLocalModelEngine?,
        unavailableReason: String?,
        headroomBytes: UInt64
    ) {
        self.isSupported = isSupported
        self.engine = engine
        self.unavailableReason = unavailableReason
        self.headroomBytes = headroomBytes
    }
}

public enum MacLocalModelAvailability {
    /// Deterministic probe inputs, injectable for focused tests. Production
    /// values reflect this Mac; tests substitute Intel-like or pre-15.4
    /// values without touching hardware.
    public struct Probe: Sendable {
        public var isAppleSilicon: Bool
        public var macOSVersion: OperatingSystemVersion
        public var hasMetalDevice: Bool
        public var physicalMemoryBytes: UInt64
        /// Memory already admitted to other in-process runtimes (a running
        /// Linux guest, another resident model). macOS does not jetsam like
        /// iOS, but the shared resource policy still subtracts reservations
        /// so a load is refused before it thrashes.
        public var reservedMemoryBytes: Int64

        public init(
            isAppleSilicon: Bool,
            macOSVersion: OperatingSystemVersion,
            hasMetalDevice: Bool,
            physicalMemoryBytes: UInt64,
            reservedMemoryBytes: Int64
        ) {
            self.isAppleSilicon = isAppleSilicon
            self.macOSVersion = macOSVersion
            self.hasMetalDevice = hasMetalDevice
            self.physicalMemoryBytes = physicalMemoryBytes
            self.reservedMemoryBytes = reservedMemoryBytes
        }
    }

    public static func currentProbe(
        reservedMemoryBytes: Int64? = nil
    ) -> Probe {
        Probe(
            isAppleSilicon: Self.isAppleSiliconHost(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
            hasMetalDevice: MTLCreateSystemDefaultDevice() != nil,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            reservedMemoryBytes: reservedMemoryBytes ?? ResidentMemoryReservations.totalBytes()
        )
    }

    /// One shared runtime verdict for settings, picker and preflight.
    public static func support(
        probe: Probe = currentProbe()
    ) -> MacLocalModelRuntimeSupport {
        let headroom = LocalInferenceResourcePolicy.effectiveHeadroomBytes(
            physicalMemoryBytes: probe.physicalMemoryBytes,
            reservedBytes: probe.reservedMemoryBytes
        )
        guard probe.isAppleSilicon else {
            return .init(
                isSupported: false,
                engine: nil,
                unavailableReason: "On-device models need Apple silicon; this Mac has an Intel processor.",
                headroomBytes: headroom
            )
        }
        guard Self.isMacOSVersionAtLeast(probe.macOSVersion, MacLocalModelRuntimeSupport.requiredMacOSVersion) else {
            return .init(
                isSupported: false,
                engine: nil,
                unavailableReason: "On-device models need macOS 15.4 or later on this Mac.",
                headroomBytes: headroom
            )
        }
        guard probe.hasMetalDevice else {
            return .init(
                isSupported: false,
                engine: nil,
                unavailableReason: "On-device models need a working Metal GPU, and none was found on this Mac.",
                headroomBytes: headroom
            )
        }
        return .init(isSupported: true, engine: .mlx, unavailableReason: nil, headroomBytes: headroom)
    }

    /// True when this process runs on Apple silicon. `hw.optional.arm64` is
    /// the documented sysctl for "the arm64 slice is executable", which is
    /// exactly the MLX Metal requirement.
    static func isAppleSiliconHost() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        guard result == 0 else { return false }
        return value != 0
    }

    /// `OperatingSystemVersion` has no `Comparable` conformance; compare the
    /// dotted fields in order.
    static func isMacOSVersionAtLeast(
        _ version: OperatingSystemVersion,
        _ required: OperatingSystemVersion
    ) -> Bool {
        if version.majorVersion != required.majorVersion {
            return version.majorVersion > required.majorVersion
        }
        if version.minorVersion != required.minorVersion {
            return version.minorVersion > required.minorVersion
        }
        return version.patchVersion >= required.patchVersion
    }
}
