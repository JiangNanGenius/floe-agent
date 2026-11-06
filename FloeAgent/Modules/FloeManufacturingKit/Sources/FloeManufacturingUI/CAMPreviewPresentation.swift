// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore

struct CAMPreviewRequest:Identifiable {
    let id = UUID()
    var source:CAMPreviewSource
    var operationID:String? = nil
    var viewState:Data? = nil
}
func camChapterName(_ value:CAMPreviewChapter)->String { camOperationName(value.name) }
func camOperationName(_ value:String)->String {
    switch value {
    case "turning-face":L("端面车削","Facing")
    case "turning-rough":L("外圆粗车","Rough turning")
    case "turning-finish","turning-profile":L("轮廓精车","Finish turning")
    case "milling-slot":L("动力刀具铣槽","Live-tool slot milling")
    case "spindle":L("主轴切换","Spindle command")
    case "chuck":L("卡盘夹持","Chuck command")
    case "transfer":L("主副轴接料","Spindle transfer")
    case "synchronize":L("主轴同步","Spindle synchronization")
    case "wait":L("通道等待","Channel wait")
    case "barrier":L("通道同步点","Channel synchronization")
    case "machine-event":L("机床辅助动作","Machine event")
    case "turning-tool":L("车刀","Turning tool")
    case "cutting-tool":L("切削刀具","Cutting tool")
    default:value
    }
}
func camMoveName(_ type:String?)->String {
    switch type { case "rapid":L("快速移动","Rapid traverse");case "retract":L("退刀","Retract");case "plunge":L("下刀","Plunge");case "dwell":L("停留","Dwell");default:L("切削","Cutting") }
}
#endif
