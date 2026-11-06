// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Compact descriptor builder used by the static catalog tables.
enum P {
    static func d(
        _ id: String, _ group: String,
        _ nameZH: String, _ nameEN: String,
        _ helpZH: String, _ helpEN: String,
        unit: ManufacturingParameterUnit = .none,
        kind: ManufacturingParameterKind,
        def: ManufacturingParameterValue? = nil,
        choices: [String]? = nil,
        min: Double? = nil, max: Double? = nil,
        binding: String? = nil,
        support: ManufacturingParameterSupport,
        reasonZH: String = "", reasonEN: String = "",
        rare: Bool = false,
        refs: [String] = []
    ) -> ManufacturingParameterDescriptor {
        ManufacturingParameterDescriptor(
            id: id, groupID: group, nameZH: nameZH, nameEN: nameEN,
            helpZH: helpZH, helpEN: helpEN,
            unit: unit, kind: kind, defaultValue: def, choices: choices,
            minimum: min, maximum: max, binding: binding,
            support: support, supportReasonZH: reasonZH, supportReasonEN: reasonEN,
            rare: rare, sourceRefs: refs
        )
    }

    // Shared honesty notes (bilingual) reused across configuration-only fields.
    static let cfgReasonZH = "当前原生预演不消费此值；仅随配置保存/导出，供完整工艺单使用。"
    static let cfgReasonEN = "The current native preview does not consume this value; it is kept with the configuration for a full process sheet."
}
