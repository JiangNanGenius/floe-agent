// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

struct EDLibraryGeometryPreview: View {
    let part: EDALibraryPart
    let footprint: Bool
    var unit = 1
    var highlighted: Set<String> = []
    private var scene: EDInspectorPreviewScene? {
        let project = EDAProject(title: part.name)
        if footprint { return part.footprint.map { .libraryFootprint($0, project: project) } }
        return part.symbol.map {
            var symbol = $0
            symbol.graphics = $0.graphics(forUnit: unit); symbol.graphicUnits = nil
            symbol.pins = $0.pins.filter { $0.unit == 0 || $0.unit == unit }
            return .symbol(symbol, project: project)
        }
    }
    private var selectedIDs: Set<UUID> {
        if footprint { return Set(part.footprint?.pads.filter { highlighted.contains($0.number) }.map(\.id) ?? []) }
        return Set(part.symbol?.pins.filter { highlighted.contains($0.number) }.map(\.id) ?? [])
    }
    var body: some View {
        Canvas { canvas, size in
            guard let scene else { return }
            let projection = EDAProjection(bounds: scene.bounds, size: size, padding: 10)
            EDAPlot.draw(project: scene.project, context: scene.context, projection: projection, selected: selectedIDs, in: &canvas)
        }
        .background(.background)
        .overlay {
            if scene == nil { Label(footprint ? edText("未关联封装", "No footprint assigned") : edText("独立封装", "Footprint only"), systemImage: footprint ? "square.dashed" : "cpu").font(.caption).foregroundStyle(.secondary) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .accessibilityLabel(footprint ? edText("封装与焊盘预览", "Footprint and pad preview") : edText("符号与引脚预览", "Symbol and pin preview"))
    }
}

enum EDLibraryLabels {
    static let categories = ["passives", "diodes-leds", "transistors-mosfets", "power", "analog-opamps", "digital-logic", "microcontrollers", "connectors", "switches-relays", "crystals", "sensors", "modules", "user"]
    static func category(_ id: String) -> String {
        let names = ["passives": ("无源器件", "Passives"), "diodes-leds": ("二极管与 LED", "Diodes & LEDs"), "transistors-mosfets": ("晶体管与 MOSFET", "Transistors & MOSFETs"),
            "power": ("电源", "Power"), "analog-opamps": ("模拟与运放", "Analog & amplifiers"), "digital-logic": ("数字逻辑", "Digital logic"), "microcontrollers": ("微控制器", "Microcontrollers"),
            "connectors": ("连接器", "Connectors"), "switches-relays": ("开关与继电器", "Switches & relays"), "crystals": ("晶振", "Crystals"), "sensors": ("传感器", "Sensors"), "modules": ("常用模块", "Modules"), "user": ("我的元件", "My parts")]
        guard let value = names[id] else { return id }; return edText(value.0, value.1)
    }
    static func kind(_ kind: EDALibraryPart.Kind) -> String {
        switch kind {
        case .device: edText("具体器件", "Specific device")
        case .generic: edText("通用器件", "Generic part")
        case .symbol: edText("独立符号", "Symbol only")
        case .footprint: edText("独立封装", "Footprint only")
        }
    }
}

extension View {
    @ViewBuilder func edLibraryInlineNavigationTitle() -> some View {
#if canImport(UIKit)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }
}
