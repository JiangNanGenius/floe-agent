import Foundation
import FloeToolboxCore

/// How far one catalog entry is from a truthful Mac implementation.
public enum MacToolReadiness: String, Sendable, Equatable {
    /// Implemented by this candidate package; not wired into the FloeMac App.
    case candidateNative
    /// Cross-platform source already exists and builds for macOS, but the Mac
    /// App has no entry point and no capability/permission verification yet.
    case reusableSource
    /// macOS has no equivalent sensor/hardware; the tool must present a
    /// truthful limitation instead of fabricated readings.
    case deviceLimited
}

public struct MacToolCoverageEntry: Sendable, Equatable {
    public let tool: ToolboxTool
    public let readiness: MacToolReadiness
    public let note: String

    public init(tool: ToolboxTool, readiness: MacToolReadiness, note: String) {
        self.tool = tool
        self.readiness = readiness
        self.note = note
    }
}

/// The 31-tool baseline from `ToolCatalog.swift`, with an honest Mac status.
/// Tests assert the real catalog still has 31 cases and that every case appears
/// exactly once here, so a future catalog change cannot silently escape review.
public enum MacToolboxBaseline {
    public static let catalogCount = 31

    /// The three tools this candidate actually implements.
    public static let candidateTools: [ToolboxTool] = [.sound, .magnifier, .scanner]

    public static let entries: [MacToolCoverageEntry] = [
        .init(tool: .terminal, readiness: .reusableSource, note: "cross-platform terminal session/workbench"),
        .init(tool: .vnc, readiness: .reusableSource, note: "cross-platform remote desktop workbench"),
        .init(tool: .browser, readiness: .reusableSource, note: "cross-platform browser workspace"),
        .init(tool: .ping, readiness: .reusableSource, note: "ICMP diagnostics service"),
        .init(tool: .traceroute, readiness: .reusableSource, note: "streaming traceroute service"),
        .init(tool: .dns, readiness: .reusableSource, note: "DNS query service"),
        .init(tool: .port, readiness: .reusableSource, note: "port probe"),
        .init(tool: .lan, readiness: .reusableSource, note: "LAN discovery; local-network authorization still to verify"),
        .init(tool: .wifi, readiness: .reusableSource, note: "Wi-Fi information has a macOS branch; real output unverified"),
        .init(tool: .roaming, readiness: .reusableSource, note: "roaming observation depends on the platform network observer"),
        .init(tool: .serialAssistant, readiness: .reusableSource, note: "TCP/UDP/BLE/serial transports"),
        .init(tool: .http, readiness: .reusableSource, note: "HTTP client workbench"),
        .init(tool: .webSocket, readiness: .reusableSource, note: "WebSocket client"),
        .init(tool: .mqtt, readiness: .reusableSource, note: "MQTT 3.1.1/5 client"),
        .init(tool: .hash, readiness: .reusableSource, note: "file checksum; user-selected file only"),
        .init(tool: .json, readiness: .reusableSource, note: "text utility"),
        .init(tool: .encoding, readiness: .reusableSource, note: "text utility"),
        .init(tool: .qr, readiness: .reusableSource, note: "QR generate/read; camera scanning is covered by scanner"),
        .init(tool: .level, readiness: .deviceLimited, note: "no Mac accelerometer/gyro equivalent"),
        .init(tool: .motion, readiness: .deviceLimited, note: "no Mac motion sensor equivalent"),
        .init(tool: .compass, readiness: .deviceLimited, note: "no Mac magnetometer equivalent"),
        .init(tool: .ruler, readiness: .reusableSource, note: "screen calibration/ruler has a macOS colour path"),
        .init(tool: .measure, readiness: .deviceLimited, note: "spatial measurement depends on ARKit-class hardware"),
        .init(tool: .calculator, readiness: .reusableSource, note: "calculator and unit conversion"),
        .init(tool: .location, readiness: .reusableSource, note: "CoreLocation exists on macOS; authorization yet unverified"),
        .init(tool: .photoMeasure, readiness: .reusableSource, note: "image measurement math is cross-platform; import adapter needed"),
        .init(tool: .barometer, readiness: .deviceLimited, note: "no Mac barometer equivalent"),
        .init(tool: .sound, readiness: .candidateNative, note: "macOS microphone analyzer in this candidate"),
        .init(tool: .magnifier, readiness: .candidateNative, note: "macOS camera magnifier in this candidate"),
        .init(tool: .scanner, readiness: .candidateNative, note: "macOS codes/OCR/pages/exports in this candidate"),
        .init(tool: .timer, readiness: .reusableSource, note: "stopwatch/timers; Mac notifications still to adapt"),
    ]

    public static func readiness(for tool: ToolboxTool) -> MacToolReadiness? {
        entries.first { $0.tool == tool }?.readiness
    }
}
