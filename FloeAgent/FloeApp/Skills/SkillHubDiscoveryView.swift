#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeSkills

/// Presentation only. Items and actions are supplied by the verified store;
/// rendering a card never downloads a package or changes effective grants.
struct SkillHubDisplayItem: Identifiable {
    enum Action: Equatable {
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
    var artworkName: String { "SkillHub-" + rawValue }
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
    /// Injected publication media service (previews/tests). Production keeps
    /// this nil and the body resolves the shared service from the AppEnvironment
    /// the view tree already injects — never from an init default argument.
    var media: SkillHubMediaCenter?
    @EnvironmentObject private var environment: AppEnvironment
    @State private var category: SkillHubCategory?
    @State private var showcase: SkillHubShowcase?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The immutable catalog publication the showcase artwork is pinned to.
    private var publicationCommit: String? {
        environment.skillsCenter.curatedPublication?.publicationCommit
    }
    private var mediaCenter: SkillHubMediaCenter {
        media ?? SkillHubMediaCenter.shared(using: environment)
    }

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
    private var featured: [SkillHubDisplayItem] {
        var seen = Set<SkillHubCategory>()
        return Array(items.filter { item in
            item.action != .unavailable && seen.insert(item.category).inserted
        }.prefix(5))
    }
    private func columns(for width: CGFloat) -> [GridItem] {
        let count = width >= 700 && !dynamicTypeSize.isAccessibilitySize ? 2 : 1
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 20), count: count)
    }

    /// One composition decision per shelf, derived from the shelf's effective
    /// column width — never per item. Build 301 feedback: a per-item
    /// `ViewThatFits` flipped the CTA below "Office" but left it inline for
    /// "PDF", so rows in the SAME shelf had inconsistent heights.
    private func shelfInlineCTA(width: CGFloat) -> Bool {
        let count = width >= 700 && !dynamicTypeSize.isAccessibilitySize ? 2 : 1
        let columnWidth = SkillHubRowLayout.columnWidth(gridWidth: width, columns: count, gutter: 20)
        return SkillHubRowLayout.prefersInlineCTA(columnWidth: columnWidth,
                                                  isAccessibilityText: dynamicTypeSize.isAccessibilitySize)
    }

    /// Same shelf-level rule for the compact per-skill thumbnail: decided
    /// once from the effective column width and applied to every row, so a
    /// shelf never mixes cover thumbnails with glyph tiles per item.
    private func shelfThumbnail(width: CGFloat) -> Bool {
        let count = width >= 700 && !dynamicTypeSize.isAccessibilitySize ? 2 : 1
        let columnWidth = SkillHubRowLayout.columnWidth(gridWidth: width, columns: count, gutter: 20)
        return SkillHubMediaLayout.prefersThumbnail(columnWidth: columnWidth,
                                                    isAccessibilityText: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if normalizedQuery.isEmpty, category == nil, !featured.isEmpty {
                        featuredShelf(wide: geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize)
                    }
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
                    } else if normalizedQuery.isEmpty, category == nil {
                        ForEach(categories) { group in
                            categoryShelf(group, width: min(geometry.size.width, 1100) - 32)
                        }
                    } else {
                    LazyVGrid(columns: columns(for: min(geometry.size.width, 1100) - 32),
                              alignment: .leading, spacing: 12) {
                        let width = min(geometry.size.width, 1100) - 32
                        let inlineCTA = shelfInlineCTA(width: width)
                        let thumbnail = shelfThumbnail(width: width)
                        ForEach(matching) { item in
                            directoryRow(item, inlineCTA: inlineCTA, thumbnail: thumbnail)
                        }
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
        // One demand per publication: the manifest load is shared and cached
        // by the service; the cards only ever show what it actually declares.
        .task(id: publicationCommit) {
            let media = mediaCenter
            media.bind(publicationCommit: publicationCommit)
            if let commit = publicationCommit {
                showcase = await media.showcase(commit: commit)
            } else {
                showcase = nil
            }
        }
    }

    private func featuredShelf(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("skills.hub.featured").font(.title2.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(featured) { item in
                        // One coherent card: artwork + text open the detail,
                        // and the category + CTA footer live INSIDE the same
                        // card background. `maxHeight: .infinity` equalizes
                        // every card to the shelf height so the row is
                        // visually consistent instead of per-item ragged.
                        VStack(alignment: .leading, spacing: 0) {
                            Button { onSelect(item.id) } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Color(red: 0.055, green: 0.055, blue: 0.11)
                                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                        .overlay {
                                            // Bundled category artwork stays the
                                            // immediate base; the real per-skill
                                            // cover overlays once the pinned
                                            // publication has validated it. A
                                            // failed image never leaves a blank
                                            // band and never touches the CTA.
                                            SkillHubFeaturedCover(
                                                ref: showcase?.cover(for: item.id),
                                                commit: publicationCommit,
                                                media: mediaCenter,
                                                artworkName: item.category.artworkName,
                                                skillID: item.id)
                                        }
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(item.title)
                                            .font(.title2.bold())
                                            .foregroundStyle(.primary)
                                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(item.summary)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(RoundedRectangle(cornerRadius: 20))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("skills.featured.\(item.id)")
                            HStack {
                                Text(item.category.title).font(.subheadline).foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                getButton(item, identifierPrefix: "skills.featured.get")
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 20))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .containerRelativeFrame(.horizontal, count: wide ? 2 : 1, spacing: 14)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("skills.featured.card.\(item.id)")
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .accessibilityIdentifier("skills.featured.carousel")
        }
    }

    private func categoryShelf(_ group: SkillHubCategory, width: CGFloat) -> some View {
        let groupItems = matching.filter { $0.category == group }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.title).font(.title2.bold())
                Spacer()
                if groupItems.count > 6 {
                    Button { category = group } label: {
                        Label("skills.hub.see_all", systemImage: "chevron.right")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                }
            }
            LazyVGrid(columns: columns(for: width), alignment: .leading, spacing: 12) {
                let inlineCTA = shelfInlineCTA(width: width)
                let thumbnail = shelfThumbnail(width: width)
                ForEach(Array(groupItems.prefix(6))) { item in
                    directoryRow(item, inlineCTA: inlineCTA, thumbnail: thumbnail)
                }
            }
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
        .accessibilityIdentifier("skills.category.\(value?.id ?? "all")")
    }

    private func directoryRow(_ item: SkillHubDisplayItem, inlineCTA: Bool, thumbnail: Bool) -> some View {
        // The composition comes from the shelf-level decision above, so every
        // row in a shelf aligns; buttons keep their natural intrinsic size.
        // The content frame FILLS the grid cell height (mirroring the
        // featured cards' `maxHeight: .infinity`): siblings whose title or
        // summary wrap to 1 vs 2 lines still paint equal card backgrounds
        // within the same shelf row — content-driven, no fixed pixel heights.
        Group {
            if inlineCTA {
                HStack(alignment: .center, spacing: 10) {
                    itemButton(item, thumbnail: thumbnail)
                    getButton(item)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    itemButton(item, thumbnail: thumbnail)
                    HStack { Spacer(); getButton(item) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.row.\(item.id)")
    }

    private func itemButton(_ item: SkillHubDisplayItem, thumbnail: Bool) -> some View {
        Button { onSelect(item.id) } label: {
            HStack(alignment: .center, spacing: 12) {
                if thumbnail {
                    // Compact per-skill cover from the pinned publication;
                    // missing/unverified/error keeps the existing glyph tile,
                    // same frame, so row heights never move.
                    SkillHubShowcaseThumbnail(
                        ref: showcase?.cover(for: item.id),
                        commit: publicationCommit,
                        media: mediaCenter,
                        category: item.category,
                        systemImage: item.systemImage,
                        skillID: item.id)
                } else {
                    Image(systemName: item.systemImage)
                        .font(.title2)
                        .foregroundStyle(item.category.tint)
                        .frame(width: 44, height: 44)
                        .background(item.category.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityHidden(true)
                }
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

    private func getButton(_ item: SkillHubDisplayItem, identifierPrefix: String = "skills.get") -> some View {
        Button { onGet(item.id) } label: {
            Text(item.action.title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .disabled(!item.actionEnabled)
        .accessibilityIdentifier("\(identifierPrefix).\(item.id)")
    }
}
#endif
