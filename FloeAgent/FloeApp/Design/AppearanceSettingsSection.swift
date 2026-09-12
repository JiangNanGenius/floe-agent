// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct AppearanceSettingsSection: View {
    @Binding var selection: AppearancePreference
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Section {
            HStack(spacing: 12) {
                ForEach(AppearancePreference.allCases, id: \.self) { preference in
                    preview(preference)
                        .environment(\.colorScheme, preference == .system ? colorScheme : preference == .light ? .light : .dark)
                }
            }
            .accessibilityHidden(true)
            if dynamicTypeSize.isAccessibilitySize {
                appearancePicker.pickerStyle(.inline)
            } else {
                appearancePicker.pickerStyle(.segmented)
            }
            Text(selection == .system
                 ? "自动随系统外观切换。定时或日落切换可在 iOS「设置 → 显示与亮度 → 自动」中设置。"
                 : "当前已固定外观，选择「自动」即可恢复跟随系统。")
                .font(.footnote).foregroundStyle(.secondary)
        } header: { Text("日间与夜间主题") }
    }
    private var appearancePicker: some View {
        Picker("日间与夜间主题", selection: $selection) {
            ForEach(AppearancePreference.allCases, id: \.self) { preference in
                Text(title(preference)).tag(preference)
            }
        }
        .accessibilityIdentifier("appearance.picker")
    }
    private func preview(_ preference: AppearancePreference) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4).fill(FloeTheme.sidebarSurface).frame(width: 20)
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(FloeTheme.primary).frame(width: 24, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.7)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(height: 4)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 4).fill(FloeTheme.fieldSurface).frame(height: 12)
            }.padding(.vertical, 5)
        }
        .padding(8).frame(minWidth: 72, maxWidth: .infinity, minHeight: 72, maxHeight: 72)
        .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selection == preference ? FloeTheme.primary : FloeTheme.separator, lineWidth: selection == preference ? 2 : 1))
        .accessibilityHidden(true)
    }
    private func title(_ preference: AppearancePreference) -> LocalizedStringKey {
        switch preference { case .system: "settings.appearance.automatic"; case .light: "settings.appearance.day"; case .dark: "settings.appearance.night" }
    }
}
#endif
