#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeTools

import FloeCore
/// Device-local feature gates for public Apple-framework integrations. The
/// switch controls whether a tool is advertised to the model; the operating
/// system remains the final authority and prompts only on first real use.
enum AppleCapability: String, CaseIterable, Identifiable, Sendable {
    case calendar, reminders, home, maps, web, watch, vision, mail, documents, camera, location, shortcuts, automation, clipboard

    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendar: FloeL10n.l("settings.apple_capabilities_settings_view.calendar")
        case .reminders: FloeL10n.l("settings.apple_capabilities_settings_view.reminders")
        case .home: FloeL10n.l("settings.apple_capabilities_settings_view.home")
        case .maps: FloeL10n.l("settings.apple_capabilities_settings_view.maps")
        case .web: "Web"
        case .watch: "Apple Watch"
        case .vision: FloeL10n.l("settings.apple_capabilities_settings_view.visual_recognition")
        case .mail: FloeL10n.l("settings.apple_capabilities_settings_view.email_composition")
        case .documents: FloeL10n.l("settings.apple_capabilities_settings_view.documents_pdf")
        case .camera: FloeL10n.l("settings.apple_capabilities_settings_view.camera")
        case .location: FloeL10n.l("settings.apple_capabilities_settings_view.position")
        case .shortcuts: "Shortcuts"
        case .automation: FloeL10n.l("settings.apple_capabilities_settings_view.automation")
        case .clipboard: FloeL10n.l("settings.apple_capabilities_settings_view.clipboard")
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
        case .calendar: FloeL10n.l("settings.apple_capabilities_settings_view.find_create_and_modify_calendar_events")
        case .reminders: FloeL10n.l("settings.apple_capabilities_settings_view.find_create_complete_and_modify_reminders")
        case .home: FloeL10n.l("settings.apple_capabilities_settings_view.read_home_structure_and_control_authorized")
        case .maps: FloeL10n.l("settings.apple_capabilities_settings_view.search_places_plan_routes_and_open")
        case .web: FloeL10n.l("settings.apple_capabilities_settings_view.browse_the_web_structurally_use_screenshot")
        case .watch: FloeL10n.l("settings.apple_capabilities_settings_view.send_task_status_to_the_paired")
        case .vision: FloeL10n.l("settings.apple_capabilities_settings_view.apple_vision_ocr_barcodes_and_the")
        case .mail: FloeL10n.l("settings.apple_capabilities_settings_view.fills_the_system_mail_composer_sending")
        case .documents: FloeL10n.l("settings.apple_capabilities_settings_view.read_edit_and_verify_workspace_documents")
        case .camera: FloeL10n.l("settings.apple_capabilities_settings_view.open_the_system_camera_and_add")
        case .location: FloeL10n.l("settings.apple_capabilities_settings_view.reads_the_current_location_once_after")
        case .shortcuts: FloeL10n.l("settings.apple_capabilities_settings_view.runs_your_shortcut_by_name_execution")
        case .automation: FloeL10n.l("settings.apple_capabilities_settings_view.create_and_manage_floe_automations_that")
        case .clipboard: FloeL10n.l("settings.apple_capabilities_settings_view.read_or_write_system_clipboard_text")
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
                Text("settings.apple_capabilities_settings_view.system_capabilities_available_to_the_agent")
            } footer: {
                Text("settings.apple_capabilities_settings_view.the_switches_here_only_decide_whether")
            }
        }
        .navigationTitle(FloeL10n.l("settings.apple_capabilities_settings_view.apple_capabilities"))
    }
}
#endif
