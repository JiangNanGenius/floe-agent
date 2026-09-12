#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeTools

/// Device-local feature gates for public Apple-framework integrations. The
/// switch controls whether a tool is advertised to the model; the operating
/// system remains the final authority and prompts only on first real use.
enum AppleCapability: String, CaseIterable, Identifiable, Sendable {
    case calendar, reminders, home, maps, web, watch, vision, mail, documents, camera, location, shortcuts, automation, clipboard

    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendar: "日历"
        case .reminders: "提醒事项"
        case .home: "家庭"
        case .maps: "地图"
        case .web: "Web"
        case .watch: "Apple Watch"
        case .vision: "视觉识别"
        case .mail: "邮件撰写"
        case .documents: "文档与 PDF"
        case .camera: "相机"
        case .location: "位置"
        case .shortcuts: "Shortcuts"
        case .automation: "自动任务"
        case .clipboard: "剪贴板"
        }
    }
    var icon: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .home: "house"
        case .maps: "map"
        case .web: "globe"
        case .watch: "applewatch"
        case .vision: "eye"
        case .mail: "envelope"
        case .documents: "doc.richtext"
        case .camera: "camera"
        case .location: "location"
        case .shortcuts: "square.on.square"
        case .automation: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .clipboard: "doc.on.clipboard"
        }
    }
    var detail: String {
        switch self {
        case .calendar: "查找、新建和修改日历事件；首次使用由系统询问权限。"
        case .reminders: "查找、新建、完成和修改提醒事项。"
        case .home: "读取家庭结构并控制已授权的 HomeKit 配件。"
        case .maps: "地点搜索、路线规划和在 Apple 地图中打开结果。"
        case .web: "结构化浏览网页；信息不足时才使用截图视觉。"
        case .watch: "向配对的 Watch 发送任务状态与接收快捷操作。"
        case .vision: "Apple Vision OCR、条码与辅助视觉模型语义读图。"
        case .mail: "填充系统邮件撰写页；发送始终由用户确认。"
        case .documents: "读取、编辑和验证工作区文档与 PDF。"
        case .camera: "打开系统相机并把用户拍摄的照片加入任务。"
        case .location: "在系统授权后读取一次当前位置。"
        case .shortcuts: "按名称运行你的快捷指令；执行与确认由快捷指令 App 控制。"
        case .automation: "创建和管理系统尽力调度的 Floe 自动任务。"
        case .clipboard: "读取或写入系统剪贴板文本；读取时系统会提示。"
        }
    }
    var toolPrefixes: [String] {
        switch self {
        case .calendar: ["apple.calendar."]
        case .reminders: ["apple.reminders."]
        case .home: ["apple.home."]
        case .maps: ["apple.maps."]
        case .web: ["browser."]
        case .watch: ["apple.watch."]
        case .vision: ["image.inspect", "image.ocr", "image.barcode.scan"]
        case .mail: ["apple.mail.compose"]
        case .documents: ["document.", "font."]
        case .camera: ["apple.camera.capture"]
        case .location: ["apple.location.current"]
        case .shortcuts: ["apple.shortcuts."]
        case .automation: ["apple.automation."]
        case .clipboard: ["apple.clipboard."]
        }
    }
}

enum AppleCapabilityPreferences {
    static let changed = Notification.Name("floe.appleCapabilities.changed")
    private static let prefix = "floe.appleCapability."

    static func isEnabled(_ capability: AppleCapability, defaults: UserDefaults = .standard) -> Bool {
        let key = prefix + capability.rawValue
        return defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func set(_ enabled: Bool, for capability: AppleCapability, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: prefix + capability.rawValue)
        NotificationCenter.default.post(name: changed, object: capability.rawValue)
    }

    static func filteredToolNames(from descriptors: [ToolCatalog.Descriptor]) -> Set<String> {
        let disabledPrefixes = AppleCapability.allCases
            .filter { !isEnabled($0) }
            .flatMap(\.toolPrefixes)
        return Set(descriptors.lazy.map(\.name).filter { name in
            !disabledPrefixes.contains(where: { prefix in
                prefix.hasSuffix(".") ? name.hasPrefix(prefix) : name == prefix
            })
        })
    }

    static func skillInstructions() -> String {
        let enabled = AppleCapability.allCases.filter { isEnabled($0) }
        guard !enabled.isEmpty else { return "" }
        let names = enabled.map(\.title).joined(separator: "、")
        return """
        ## Apple system integrations
        Enabled on this device: \(names).
        Use only the corresponding compiled tools. Ask for the minimum system permission at first real use, handle denial without retry loops, and never claim that a system-owned UI was confirmed. Mail sending, camera capture, Home access, and other system consent remain user-controlled.
        When Apple workflow guidance is needed, read floe-apple with skill.read; reuse the current guide if already read. Known tool calls do not require a guide. App enablement does not prove operating-system permission has been granted.
        """
    }
}

struct AppleCapabilitiesSettingsView: View {
    @State private var values = Dictionary(uniqueKeysWithValues: AppleCapability.allCases.map {
        ($0, AppleCapabilityPreferences.isEnabled($0))
    })

    var body: some View {
        Form {
            Section {
                ForEach(AppleCapability.allCases) { capability in
                    Toggle(isOn: Binding(
                        get: { values[capability] ?? true },
                        set: {
                            values[capability] = $0
                            AppleCapabilityPreferences.set($0, for: capability)
                        }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(capability.title)
                                Text(capability.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: capability.icon)
                        }
                    }
                    .accessibilityIdentifier("settings.apple.\(capability.rawValue)")
                }
            } header: {
                Text("可供 Agent 使用的系统能力")
            } footer: {
                Text("这里的开关只决定 Floe 是否向模型提供能力，不会替代 iOS 权限。系统权限、本机路径、Face ID 和 Home 数据不会跨设备同步。")
            }
        }
        .navigationTitle("Apple 能力")
    }
}
#endif
