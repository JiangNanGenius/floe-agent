// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench

extension MediaV2Session {
    static func updatedVideoGrade(tool: String, input: MediaV2ToolInput, current: MediaVideoGrade?) throws -> MediaVideoGrade? {
        var grade = current ?? .init()
        switch tool {
        case "video.video-curves":
            if input.flag == false { grade.toneCurve = nil }
            else {
                guard let curve = input.videoGrade?.toneCurve ?? input.adjustment?.toneCurve ?? input.points else { throw MediaV2CommandError.invalidInput }
                grade.toneCurve = curve
            }
        case "video.wheels":
            if input.flag == false { grade.colorBalance = nil }
            else {
                guard let balance = input.videoGrade?.colorBalance ?? input.adjustment?.colorBalance else { throw MediaV2CommandError.invalidInput }
                grade.colorBalance = balance
            }
        case "video.video-hsl":
            if input.flag == false { grade.secondary = nil }
            else {
                guard let secondary = input.videoGrade?.secondary else { throw MediaV2CommandError.invalidInput }
                grade.secondary = secondary
            }
        case "video.video-lut":
            if input.flag == false { grade.colorLUT = nil;grade.filterID = nil;grade.lutName = nil }
            else if let lut = input.videoGrade?.colorLUT ?? input.adjustment?.colorLUT {
                grade.colorLUT = lut;grade.filterID = nil;grade.lutName = input.videoGrade?.lutName
            } else if let filter = input.videoGrade?.filterID ?? input.text {
                grade.filterID = filter;grade.colorLUT = nil;grade.lutName = nil
            } else { throw MediaV2CommandError.invalidInput }
        default: throw MediaV2CommandError.unavailable
        }
        try grade.validate()
        return grade.isEmpty ? nil : grade
    }
}
#endif
