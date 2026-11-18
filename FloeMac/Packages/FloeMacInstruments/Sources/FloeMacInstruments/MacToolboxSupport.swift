// SPDX-License-Identifier: MPL-2.0
//
// Mac toolbox instruments — catalog, availability and shared copy.
//
// This file is part of a reviewable patch proposed for the native macOS host.
// It does not start sensors, request permissions or read user data on its own.

import Foundation
import FloeToolboxCore

/// Bilingual copy chosen at render time. The Mac host currently ships plain
/// `.strings` resources rather than a string catalog, so instrument copy stays
/// next to the capability that owns it and never depends on a missing key.
public func macToolboxText(_ zh: String, _ en: String, _ locale: Locale) -> String {
    locale.language.languageCode?.identifier == "zh" ? zh : en
}

public struct MacInstrumentNotice: Equatable, Sendable {
    public let zh: String
    public let en: String
    public init(zh: String, en: String) {
        self.zh = zh
        self.en = en
    }
    public func text(_ locale: Locale) -> String { macToolboxText(zh, en, locale) }
}

/// The eight instrument entries in the existing Floe toolbox. Identifiers map
/// to `ToolboxTool` so navigation, search and future analytics do not invent a
/// parallel taxonomy.
public enum MacInstrument: String, CaseIterable, Identifiable, Sendable {
    case level
    case motion
    case compass
    case ruler
    case spatialMeasurement
    case location
    case photoMeasurement
    case barometer

    public var id: String { rawValue }

    public var toolboxTool: ToolboxTool {
        switch self {
        case .level: .level
        case .motion: .motion
        case .compass: .compass
        case .ruler: .ruler
        case .spatialMeasurement: .measure
        case .location: .location
        case .photoMeasurement: .photoMeasure
        case .barometer: .barometer
        }
    }

    public var systemImage: String {
        switch self {
        case .level: "bubble.middle.bottom"
        case .motion: "gyroscope"
        case .compass: "compass.drawing"
        case .ruler: "ruler"
        case .spatialMeasurement: "ruler.fill"
        case .location: "location"
        case .photoMeasurement: "photo.badge.plus"
        case .barometer: "gauge.with.dots.needle.33percent"
        }
    }

    public func title(_ locale: Locale) -> String {
        switch self {
        case .level: macToolboxText("水平仪", "Level", locale)
        case .motion: macToolboxText("运动", "Motion", locale)
        case .compass: macToolboxText("指南针", "Compass", locale)
        case .ruler: macToolboxText("标尺", "Ruler", locale)
        case .spatialMeasurement: macToolboxText("空间测量", "Spatial measure", locale)
        case .location: macToolboxText("位置", "Location", locale)
        case .photoMeasurement: macToolboxText("图片测量", "Photo measure", locale)
        case .barometer: macToolboxText("气压", "Barometer", locale)
        }
    }

    public func subtitle(_ locale: Locale) -> String {
        switch self {
        case .level: macToolboxText("双轴气泡水平", "Two-axis bubble level", locale)
        case .motion: macToolboxText("加速度与姿态", "Acceleration and attitude", locale)
        case .compass: macToolboxText("磁北朝向", "Magnetic heading", locale)
        case .ruler: macToolboxText("按显示器校准", "Calibrated per display", locale)
        case .spatialMeasurement: macToolboxText("AR 世界追踪", "AR world tracking", locale)
        case .location: macToolboxText("系统定位采样", "System location sampling", locale)
        case .photoMeasurement: macToolboxText("尺度标定与测量", "Scale calibration and measurement", locale)
        case .barometer: macToolboxText("气压与相对高度", "Pressure and relative altitude", locale)
        }
    }
}

public enum MacInstrumentAvailability: Equatable, Sendable {
    /// The instrument has a real implementation in this Mac target.
    case available
    /// A system setting or permission must be resolved before it can work.
    case needsSetup(MacInstrumentNotice)
    /// No public API is available to this native Mac target. The entry stays
    /// visible with the actual reason and must not fabricate a reading.
    case unsupported(MacInstrumentNotice)
}

/// Narrow platform seam. Tests inject a fake; the production value asks the
/// system whether Location Services is enabled. Sensor APIs that are marked
/// unavailable in the macOS SDK are not forced on with private IOKit access.
@MainActor
public protocol MacInstrumentPlatform: AnyObject {
    func locationServicesEnabled() -> Bool
}

@MainActor
public final class NativeMacInstrumentPlatform: MacInstrumentPlatform {
    public init() {}

    public func locationServicesEnabled() -> Bool {
        // This is a service-state query, not a permission request and not a
        // location sample. It is the same system authority a user sees in
        // System Settings; no second location manager is created here.
        #if os(macOS)
        return MacLocationSystem.serviceEnabled()
        #else
        return false
        #endif
    }
}

@MainActor
public struct MacInstrumentCatalog {
    private let platform: any MacInstrumentPlatform

    public init(platform: any MacInstrumentPlatform = NativeMacInstrumentPlatform()) {
        self.platform = platform
    }

    public func availability(for instrument: MacInstrument) -> MacInstrumentAvailability {
        switch instrument {
        case .ruler, .photoMeasurement:
            return .available
        case .location:
            guard platform.locationServicesEnabled() else {
                return .needsSetup(MacInstrumentNotice(
                    zh: "系统定位服务已关闭。请在系统设置中打开定位服务后再使用。",
                    en: "Location Services is off. Turn it on in System Settings before locating."))
            }
            return .available
        case .level:
            return .unsupported(MacInstrumentNotice(
                zh: "macOS 没有向原生 Mac App 提供设备运动传感器接口（CMMotionManager 在 macOS SDK 中不可用）。此 Mac 版本不显示水平读数，也不使用私有接口猜测角度。",
                en: "macOS does not expose device-motion sensors to native Mac apps (CMMotionManager is unavailable in the macOS SDK). This Mac build shows no level reading and does not guess an angle through private APIs."))
        case .motion:
            return .unsupported(MacInstrumentNotice(
                zh: "macOS 没有向原生 Mac App 提供设备运动传感器接口（CMMotionManager 在 macOS SDK 中不可用）。此 Mac 版本不显示加速度、角速度或姿态读数。",
                en: "macOS does not expose device-motion sensors to native Mac apps (CMMotionManager is unavailable in the macOS SDK). This Mac build shows no acceleration, rotation-rate or attitude readings."))
        case .compass:
            return .unsupported(MacInstrumentNotice(
                zh: "macOS 没有向原生 Mac App 提供磁力计接口（CMMotionManager 在 macOS SDK 中不可用）。此 Mac 版本不显示磁北朝向。",
                en: "macOS does not expose a magnetometer to native Mac apps (CMMotionManager is unavailable in the macOS SDK). This Mac build shows no magnetic heading."))
        case .barometer:
            return .unsupported(MacInstrumentNotice(
                zh: "macOS 没有向原生 Mac App 提供 CMAltimeter 气压计接口。此 Mac 版本不显示气压或相对高度，也不以天气数据或其他来源冒充传感器读数。",
                en: "macOS does not expose the CMAltimeter barometer to native Mac apps. This Mac build shows no pressure or relative altitude and does not substitute weather data or another source for a sensor reading."))
        case .spatialMeasurement:
            return .unsupported(MacInstrumentNotice(
                zh: "macOS SDK 未提供 ARKit 世界追踪接口（ARWorldTrackingConfiguration 在 macOS SDK 中不可用）。此 Mac 版本不开始 AR 会话，也不把普通摄像头画面当作空间测量。",
                en: "The macOS SDK does not provide ARKit world tracking (ARWorldTrackingConfiguration is unavailable in the macOS SDK). This Mac build does not start an AR session or treat an ordinary camera image as a spatial measurement."))
        }
    }

    /// Instruments that can actually be opened in this build, in sidebar order.
    public var implementedInstruments: [MacInstrument] {
        [.location, .ruler, .photoMeasurement]
    }
}
