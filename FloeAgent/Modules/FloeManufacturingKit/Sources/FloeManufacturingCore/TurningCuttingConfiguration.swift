// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeManufacturingParameters

extension TurningCuttingParameters {
    /// Demonstration values only; not a material/tool recommendation.
    public static var researchExample: Self {
        .init(spindleMode:.constantSurfaceSpeed,feedMode:.mmPerRevolution,
              spindleRPM:1200,surfaceSpeedMPerMinute:120,maxSpindleRPM:3000,feedMMPerRevolution:0.1)
    }
}

extension ManufacturingStudy {
    /// Inactive settings remain process-sheet configuration, without enabling a speed law.
    public var configuredTurningCutting: TurningCuttingParameters {
        if let turningCutting { return turningCutting }
        var value = TurningCuttingParameters.researchExample
        if let raw = parameters?.value("feeds.turning.spindleMode")?.stringValue,
           let mode = TurningCuttingParameters.SpindleMode(rawValue:raw) { value.spindleMode = mode }
        if let raw = parameters?.value("feeds.turning.feedMode")?.stringValue,
           let mode = TurningCuttingParameters.FeedMode(rawValue:raw) { value.feedMode = mode }
        if let number = parameters?.value("feeds.spindle.rpm")?.numericMagnitude { value.spindleRPM = number }
        if let number = parameters?.value("feeds.spindle.cssMPerMin")?.numericMagnitude { value.surfaceSpeedMPerMinute = number }
        if let number = parameters?.value("machine.spindle.maxRPM")?.numericMagnitude { value.maxSpindleRPM = number }
        if let number = parameters?.value("feeds.cutting.mmPerRevolution")?.numericMagnitude { value.feedMMPerRevolution = number }
        return value
    }
    public func applyingTurningCutting(_ settings:TurningCuttingParameters, enabled:Bool) throws -> Self {
        var draft = self
        draft.turningCutting = enabled ? settings : nil
        var stored = parameters ?? .init()
        let fields: [String:ManufacturingParameterValue] = [
            "feeds.turning.spindleMode":.string(settings.spindleMode.rawValue),
            "feeds.turning.feedMode":.string(settings.feedMode.rawValue),
            "feeds.spindle.rpm":.number(settings.spindleRPM),
            "feeds.spindle.cssMPerMin":.number(settings.surfaceSpeedMPerMinute),
            "machine.spindle.maxRPM":.number(settings.maxSpindleRPM),
            "feeds.cutting.mmPerRevolution":.number(settings.feedMMPerRevolution)
        ]
        for (key,value) in fields {
            if enabled { stored.remove(key) } else { stored.set(key,value) }
        }
        draft.parameters = stored
        try draft.validate()
        return draft
    }
    public static func cuttingSpeedExample() -> Self {
        var study = shaft()
        study.name = "恒线速车削"
        study.turningCutting = .researchExample
        return study
    }
}
