#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Presentation only. Items and actions are supplied by the verified store;
/// rendering a card never downloads a package or changes effective grants.
struct SkillHubDisplayItem: Identifiable {
    enum Action {
        case get, added, enable, update, unavailable
        var title: LocalizedStringKey {
            switch self {
            case .get: "skills.hub.get"
            case .added: "skills.hub.added"
            case .enable: "plugins.enable"
            case .update: "skills.update.now"
            case .unavailable: "skills.hub.unavailable"
            }
        }
    }
    let id: String
    let title: String
    let summary: String
    let category: SkillHubCategory
    let systemImage: String
    let action: Action
    let actionEnabled: Bool
}

enum SkillHubCategory: String, CaseIterable, Identifiable {
    case office, writing, research, design, development, product, productivity
    var id: String { rawValue }
    var title: LocalizedStringKey { LocalizedStringKey("skills.hub.category." + rawValue) }
    var tint: Color {
        switch self {
        case .office: .blue
        case .writing: .indigo
        case .research: .teal
        case .design: .purple
        case .development: .cyan
        case .product: .orange
        case .productivity: .green
        }
    }
}

struct SkillHubDiscoveryView<Connections: View>: View {
    let items: [SkillHubDisplayItem]
    let query: String
    let onSelect: (String) -> Void
    let onGet: (String) -> Void
    @ViewBuilder let connections: () -> Connections
    @State private var category: SkillHubCategory?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var matching: [SkillHubDisplayItem] {
        items.filter {
            (category == nil || $0.category == category)
                && (normalizedQuery.isEmpty || $0.title.localizedStandardContains(normalizedQuery)
                    || $0.summary.localizedStandardContains(normalizedQuery))
        }
    }
    private var categories: [SkillHubCategory] {
        SkillHubCategory.allCases.filter { category in items.contains { $0.category == category } }
    }
    private func columns(for width: CGFloat) -> [GridItem] {
        let count = width >= 700 && !dynamicTypeSize.isAccessibilitySize ? 2 : 1
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 20), count: count)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if categories.count > 1 {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                categoryButton(nil)
                                ForEach(categories) { categoryButton($0) }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollIndicators(.hidden)
                    }
                    if matching.isEmpty {
                        if normalizedQuery.isEmpty {
                            ContentUnavailableView("skills.empty", systemImage: "puzzlepiece.extension")
                        } else {
                            ContentUnavailableView.search(text: normalizedQuery)
                        }
                    } else {
                        LazyVGrid(columns: columns(for: min(geometry.size.width, 1100) - 32),
                                  alignment: .leading, spacing: 12) {
                            ForEach(matching) { item in directoryRow(item) }
                        }
                    }
                    if normalizedQuery.isEmpty { connections() }
                }
                .padding(16)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onChange(of: categories) { _, values in
            if let category, !values.contains(category) { self.category = nil }
        }
    }

    private func categoryButton(_ value: SkillHubCategory?) -> some View {
        Button { category = value } label: {
            Text(value?.title ?? "skills.hub.all")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(category == value ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(category == value ? Color.accentColor : .primary)
        .accessibilityAddTraits(category == value ? .isSelected : [])
    }

    private func directoryRow(_ item: SkillHubDisplayItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                itemButton(item)
                getButton(item)
            }
            VStack(alignment: .leading, spacing: 10) {
                itemButton(item)
                HStack { Spacer(); getButton(item) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func itemButton(_ item: SkillHubDisplayItem) -> some View {
        Button { onSelect(item.id) } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.title2)
                    .foregroundStyle(item.category.tint)
                    .frame(width: 44, height: 44)
                    .background(item.category.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.headline).foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.summary).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("skills.card.\(item.id)")
    }

    private func getButton(_ item: SkillHubDisplayItem) -> some View {
        Button { onGet(item.id) } label: {
            Text(item.action.title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .disabled(!item.actionEnabled)
        .accessibilityIdentifier("skills.get.\(item.id)")
    }
}
#endif
