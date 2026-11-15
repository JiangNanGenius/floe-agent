// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Floe contributors

import Foundation

/// One optional image capability. `available` is meaningful only when an
/// exact artifact/qualification `evidence` string is present; a declaration
/// without evidence is an error, never a soft "maybe".
public struct LinuxGraphicsFeature: Codable, Sendable, Equatable {
    public var available: Bool
    public var evidence: String?
    public var limitation: String?

    public init(available: Bool = false, evidence: String? = nil, limitation: String? = nil) {
        self.available = available
        self.evidence = evidence
        self.limitation = limitation
    }

    public var isVerified: Bool {
        guard available, let evidence else { return false }
        return !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Video nodes are separate from Vulkan. `nativeSoftware` is CPU/library
/// codec work and must never be presented as GPU or hardware acceleration.
public struct LinuxVideoGraphicsCapabilities: Codable, Sendable, Equatable {
    public var hardwareDecode: LinuxGraphicsFeature?
    public var hardwareEncode: LinuxGraphicsFeature?
    public var nativeSoftware: LinuxGraphicsFeature?

    public init(hardwareDecode: LinuxGraphicsFeature? = nil,
                hardwareEncode: LinuxGraphicsFeature? = nil,
                nativeSoftware: LinuxGraphicsFeature? = nil) {
        self.hardwareDecode = hardwareDecode
        self.hardwareEncode = hardwareEncode
        self.nativeSoftware = nativeSoftware
    }
}

/// Optional `graphics` block in a verified guest image manifest.
///
/// This is a declaration of what the installed image contains, not a live
/// probe. The producer is `FloeAgent/scripts/graphics/emit_capabilities.py`,
/// which binds each available feature to installed artifact digests.
public struct LinuxGraphicsCapabilities: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var venusVulkan: LinuxGraphicsFeature?
    public var openGL: LinuxGraphicsFeature?
    public var openCL: LinuxGraphicsFeature?
    public var shaderCache: LinuxGraphicsFeature?
    public var video: LinuxVideoGraphicsCapabilities?

    public init(schemaVersion: Int = LinuxGraphicsCapabilities.currentSchemaVersion,
                venusVulkan: LinuxGraphicsFeature? = nil,
                openGL: LinuxGraphicsFeature? = nil,
                openCL: LinuxGraphicsFeature? = nil,
                shaderCache: LinuxGraphicsFeature? = nil,
                video: LinuxVideoGraphicsCapabilities? = nil) {
        self.schemaVersion = schemaVersion
        self.venusVulkan = venusVulkan
        self.openGL = openGL
        self.openCL = openCL
        self.shaderCache = shaderCache
        self.video = video
    }

    public enum Issue: Error, Sendable, Equatable, CustomStringConvertible {
        case unsupportedSchema(Int)
        case missingEvidence(String)
        case evidenceWithoutAvailability(String)
        case gateNotSatisfied(String, String)

        public var description: String {
            switch self {
            case .unsupportedSchema(let version):
                return "unsupported graphics capability schema \(version)"
            case .missingEvidence(let name):
                return "\(name) is declared available without artifact evidence"
            case .evidenceWithoutAvailability(let name):
                return "\(name) carries evidence but is not available"
            case .gateNotSatisfied(let name, let gate):
                return "\(name) requires \(gate)"
            }
        }
    }

    /// Returns every structural/gating problem instead of the first one so a
    /// caller can log a precise refusal. An empty result means the declaration
    /// is internally sound; it still only describes the installed image.
    public func issues() -> [Issue] {
        var result: [Issue] = []
        if schemaVersion != Self.currentSchemaVersion {
            result.append(.unsupportedSchema(schemaVersion))
        }
        check(venusVulkan, name: "venusVulkan", into: &result)
        check(openGL, name: "openGL", into: &result)
        check(openCL, name: "openCL", into: &result)
        check(shaderCache, name: "shaderCache", into: &result)
        check(video?.hardwareDecode, name: "video.hardwareDecode", into: &result)
        check(video?.hardwareEncode, name: "video.hardwareEncode", into: &result)
        check(video?.nativeSoftware, name: "video.nativeSoftware", into: &result)

        if openGL?.isVerified == true, venusVulkan?.isVerified != true {
            result.append(.gateNotSatisfied("openGL", "venusVulkan"))
        }
        if openCL?.isVerified == true, venusVulkan?.isVerified != true {
            result.append(.gateNotSatisfied("openCL", "venusVulkan"))
        }
        if shaderCache?.isVerified == true, openGL?.isVerified != true {
            result.append(.gateNotSatisfied("shaderCache", "openGL"))
        }
        return result
    }

    public var isValid: Bool { issues().isEmpty }

    private func check(_ feature: LinuxGraphicsFeature?, name: String, into result: inout [Issue]) {
        guard let feature else { return }
        if feature.available, !feature.isVerified {
            result.append(.missingEvidence(name))
        }
        if !feature.available, feature.evidence != nil {
            result.append(.evidenceWithoutAvailability(name))
        }
    }
}

/// Live runtime facts supplied by the existing ARM64 GPU budget API. Unknown
/// values remain nil (`present` is nil while stopped or when the engine cannot
/// answer). No field is inferred from the image declaration.
public struct LinuxGraphicsRuntimeSnapshot: Sendable, Equatable {
    public var guestRunning: Bool
    public var gpuPresent: Bool?
    public var needsReset: Bool
    public var effectiveBytes: UInt64?
    public var targetBytes: UInt64?

    public init(guestRunning: Bool, gpuPresent: Bool?, needsReset: Bool = false,
                effectiveBytes: UInt64? = nil, targetBytes: UInt64? = nil) {
        self.guestRunning = guestRunning
        self.gpuPresent = gpuPresent
        self.needsReset = needsReset
        self.effectiveBytes = effectiveBytes
        self.targetBytes = targetBytes
    }
}

/// A presentation-only projection. It separates "installed image declares
/// this" from "the live device currently provides it" so an unavailable
/// renderer is never shown as active.
public struct LinuxGraphicsStatus: Sendable, Equatable {
    public enum Summary: Sendable, Equatable {
        case noDeclaredCapabilities
        case guestStopped
        case cpuOnly
        case needsReset
        case ready(effectiveBytes: UInt64?)
    }

    public var summary: Summary
    public var venusVulkan: Bool
    public var openGL: Bool
    public var openCL: Bool
    public var shaderCache: Bool
    public var videoHardwareDecode: Bool
    public var videoHardwareEncode: Bool
    public var videoNativeSoftware: Bool
    public var limitations: [String]

    public init(capabilities: LinuxGraphicsCapabilities?,
                runtime: LinuxGraphicsRuntimeSnapshot) {
        let declared = capabilities
        let valid = declared?.isValid == true ? declared : nil
        var collectedLimitations = declared?.issues().map(\.description) ?? []

        let venus = valid?.venusVulkan?.isVerified == true
        let running = runtime.guestRunning
        let gpuAvailable = running && venus && runtime.gpuPresent == true && !runtime.needsReset
        let cpuOnly = running && (runtime.gpuPresent == false || !venus)
        let reset = running && runtime.needsReset

        venusVulkan = gpuAvailable
        openGL = gpuAvailable && valid?.openGL?.isVerified == true
        openCL = gpuAvailable && valid?.openCL?.isVerified == true
        shaderCache = openGL && valid?.shaderCache?.isVerified == true
        videoHardwareDecode = running && valid?.video?.hardwareDecode?.isVerified == true
        videoHardwareEncode = running && valid?.video?.hardwareEncode?.isVerified == true
        videoNativeSoftware = running && valid?.video?.nativeSoftware?.isVerified == true

        for feature in [valid?.venusVulkan, valid?.openGL, valid?.openCL, valid?.shaderCache] {
            if let limitation = feature?.limitation, !limitation.isEmpty {
                collectedLimitations.append(limitation)
            }
        }
        limitations = Array(Set(collectedLimitations)).sorted()

        if valid == nil {
            summary = .noDeclaredCapabilities
        } else if !running {
            summary = .guestStopped
        } else if reset {
            summary = .needsReset
        } else if venus && runtime.gpuPresent == true {
            summary = .ready(effectiveBytes: runtime.effectiveBytes)
        } else if cpuOnly || !venus {
            summary = .cpuOnly
        } else {
            summary = .cpuOnly
        }
    }

}
