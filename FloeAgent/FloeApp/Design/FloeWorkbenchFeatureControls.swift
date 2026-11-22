// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeModels
import SwiftUI

struct FloeTaskApprovalSection: View {
    @Binding var mode: TaskApprovalMode
    let allowsFullAccess: Bool
    let explanation: String

    var body: some View {
        Section(FloeL10n.isChinese ? "审批模式" : "Approval Mode") {
            Picker(FloeL10n.isChinese ? "此任务" : "This Task", selection: $mode) {
                ForEach(TaskApprovalMode.allCases, id: \.self) { choice in
                    Text(Self.title(choice)).tag(choice)
                        .disabled(choice == .fullAccess && !allowsFullAccess)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("task.permissions.approval")
            Text(explanation).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func title(_ mode: TaskApprovalMode) -> String {
        switch mode {
        case .ask: FloeL10n.isChinese ? "询问" : "Ask"
        case .automatic: FloeL10n.isChinese ? "自动审批" : "Auto Approve"
        case .fullAccess: FloeL10n.isChinese ? "完全访问" : "Full Access"
        }
    }
}

struct FloeCanvasStartRow: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.and.pencil.and.ellipsis").foregroundStyle(FloeTheme.primary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(FloeL10n.isChinese ? "新建画布" : "New Canvas").foregroundStyle(.primary)
                    Text(FloeL10n.isChinese ? "从目标、场景或空白开始" : "Start with a goal, scenario, or blank canvas")
                        .font(FloeTheme.Typography.metadata).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityIdentifier("canvas.home.create")
    }
}

struct FloeCanvasLibraryRow<Metadata: View>: View {
    let title: String
    var excerpt: String? = nil
    @ViewBuilder let metadata: () -> Metadata

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(FloeTheme.primary.opacity(0.12))
                .frame(width: 52, height: 38)
                .overlay { Image(systemName: "rectangle.and.pencil.and.ellipsis") }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                if let excerpt, !excerpt.isEmpty {
                    Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                metadata().font(FloeTheme.Typography.metadata).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .contentShape(Rectangle())
    }
}

struct FloeBrowserTabStrip: View {
    struct Tab: Identifiable {
        let id: UUID
        let title: String
        let active: Bool
    }

    let tabs: [Tab]
    let onOpen: () -> Void
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void

    private var newTab: String { FloeL10n.isChinese ? "新建标签页" : "New Tab" }
    private var closeTab: String { FloeL10n.isChinese ? "关闭标签页" : "Close Tab" }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    HStack(spacing: 0) {
                        Button { onClose(tab.id) } label: {
                            Image(systemName: "xmark").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(closeTab)
                        Button { onSelect(tab.id) } label: {
                            Text(tab.title.isEmpty ? newTab : tab.title).font(.subheadline).lineLimit(1)
                                .foregroundStyle(tab.active ? .primary : .secondary)
                                .padding(.trailing, 16)
                                .frame(minWidth: 80, maxWidth: 180, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(tab.active ? .isSelected : [])
                    }
                    .background(tab.active ? FloeTheme.readingSurface : .clear,
                                in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
                    .accessibilityElement(children: .contain)
                }
                Button(action: onOpen) {
                    Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(newTab).accessibilityIdentifier("browser.newTab")
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44)
    }
}
