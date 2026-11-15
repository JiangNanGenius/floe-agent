// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Floe contributors

import Foundation

/// Strict reader for a guest-produced graphics report (for example the future
/// `floe-accel graphics status --json`). A report is accepted only when it
/// names a real physical/virtual device and does not select a software Vulkan
/// or OpenGL renderer. Missing data never becomes a success.
public struct LinuxGraphicsProbeReport: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public struct OpenGL: Codable, Sendable, Equatable {
        public var renderer: String?
        public var version: String?
        public var hardware: Bool?

        public init(renderer: String? = nil, version: String? = nil, hardware: Bool? = nil) {
            self.renderer = renderer
            self.version = version
            self.hardware = hardware
        }
    }

    public struct Video: Codable, Sendable, Equatable {
        public var decoderNodes: Int?
        public var encoderNodes: Int?
        public var hardwareDecode: Bool?
        public var hardwareEncode: Bool?
        public var nativeSoftware: Bool?

        public init(decoderNodes: Int? = nil, encoderNodes: Int? = nil,
                    hardwareDecode: Bool? = nil, hardwareEncode: Bool? = nil,
                    nativeSoftware: Bool? = nil) {
            self.decoderNodes = decoderNodes
            self.encoderNodes = encoderNodes
            self.hardwareDecode = hardwareDecode
            self.hardwareEncode = hardwareEncode
            self.nativeSoftware = nativeSoftware
        }
    }

    public var schemaVersion: Int
    public var device: String
    public var deviceType: String
    public var apiVersion: UInt32
    public var venus: Bool
    public var softwareDevice: Bool?
    public var openGL: OpenGL?
    public var video: Video?

    public init(schemaVersion: Int = Self.currentSchemaVersion, device: String,
                deviceType: String, apiVersion: UInt32, venus: Bool,
                softwareDevice: Bool? = nil, openGL: OpenGL? = nil, video: Video? = nil) {
        self.schemaVersion = schemaVersion
        self.device = device
        self.deviceType = deviceType
        self.apiVersion = apiVersion
        self.venus = venus
        self.softwareDevice = softwareDevice
        self.openGL = openGL
        self.video = video
    }

    public enum Rejection: Error, Sendable, Equatable, CustomStringConvertible {
        case unsupportedSchema(Int)
        case missingDevice
        case unsupportedDeviceType(String)
        case softwareVulkan
        case venusDisabled
        case missingOpenGLRenderer
        case softwareOpenGL(String)

        public var description: String {
            switch self {
            case .unsupportedSchema(let version):
                return "unsupported graphics probe schema \(version)"
            case .missingDevice:
                return "graphics probe did not name a device"
            case .unsupportedDeviceType(let type):
                return "graphics probe device type is \(type), not a physical/virtual GPU"
            case .softwareVulkan:
                return "graphics probe selected a software Vulkan device"
            case .venusDisabled:
                return "graphics probe did not report an enabled Venus capset"
            case .missingOpenGLRenderer:
                return "graphics probe reported OpenGL without a renderer"
            case .softwareOpenGL(let renderer):
                return "OpenGL renderer \(renderer) is software"
            }
        }
    }

    private static let allowedDeviceTypes: Set<String> = ["integrated", "discrete", "virtual"]
    private static let softwareRendererMarkers = [
        "llvmpipe", "softpipe", "swrast", "software rasterizer", "lavapipe"
    ]

    public func rejections() -> [Rejection] {
        var result: [Rejection] = []
        if schemaVersion != Self.currentSchemaVersion {
            result.append(.unsupportedSchema(schemaVersion))
        }
        if device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.missingDevice)
        }
        let type = deviceType.lowercased()
        if !Self.allowedDeviceTypes.contains(type) {
            result.append(.unsupportedDeviceType(deviceType))
        }
        if softwareDevice == true {
            result.append(.softwareVulkan)
        }
        if !venus {
            result.append(.venusDisabled)
        }
        if let openGL {
            let renderer = openGL.renderer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if renderer.isEmpty {
                result.append(.missingOpenGLRenderer)
            } else {
                let lowered = renderer.lowercased()
                if Self.softwareRendererMarkers.contains(where: lowered.contains) {
                    result.append(.softwareOpenGL(renderer))
                }
            }
            if openGL.hardware == false {
                result.append(.softwareOpenGL(renderer.isEmpty ? "unknown" : renderer))
            }
        }
        return result
    }

    public var isTrustworthy: Bool { rejections().isEmpty }
}
