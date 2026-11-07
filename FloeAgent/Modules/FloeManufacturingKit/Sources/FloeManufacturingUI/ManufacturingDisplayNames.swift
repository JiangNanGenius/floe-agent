// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation

/// Localized labels for the known built-in examples only. Serialized names,
/// user-authored names, source identities and result hashes stay untouched.
enum ManufacturingDisplayNames {
    static func spindle(name: String, id: String) -> String {
        switch (id, name) {
        case ("main", "Main spindle"): L("主轴", "Main spindle")
        case ("sub", "Sub spindle"): L("副主轴", "Sub spindle")
        default: name
        }
    }
    static func cell(name: String) -> String {
        name == "Opposing spindle two-turret demo"
            ? L("对置主轴双刀塔示例", "Opposing spindle two-turret demo") : name
    }
}
#endif
