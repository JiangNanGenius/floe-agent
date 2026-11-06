// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeDiagramCore

/// Matches FloeApp/Notes/NotesPalettePresentation.swift without depending on the App target.
struct DiagramChromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
    }
}

/// Uses the Notes document-tab rhythm and FloeTheme semantic surfaces.
/// Page identity and every edit still belong to the existing editor model.
struct DiagramPageBar: View {
    let model: DiagramEditorModel
    let compact: Bool
    let renamePage: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var menuOnly: Bool { compact || dynamicTypeSize.isAccessibilitySize }
    private var pageSelection: Binding<UUID> { Binding(get: { model.pageID }, set: { model.selectPage($0) }) }

    var body: some View {
        Group {
            if menuOnly { compactControls }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { pageMenu(showTitle: false); pageTabs; addPage }.fixedSize(horizontal: true, vertical: true)
                    compactControls
                }
            }
        }
        .buttonStyle(DiagramChromeButtonStyle())
        .foregroundStyle(.primary)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
    private var compactControls: some View {
        HStack(spacing: 4) { pageMenu(showTitle: true); addPage }
    }
    private var addPage: some View {
        Button { model.addPage() } label: { Label(DL("添加页面", "Add page"), systemImage: "plus").labelStyle(.iconOnly) }
            .accessibilityIdentifier("diagram.addPage").help(DL("添加页面", "Add page"))
    }
    private var pageTabs: some View {
        HStack(spacing: 4) {
            ForEach(model.document.pages) { page in
                Button { model.selectPage(page.id) } label: {
                    Text(page.title).font(.subheadline.weight(model.pageID == page.id ? .semibold : .regular))
                        .lineLimit(1).padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(model.pageID == page.id ? Color.accentColor : .primary)
                        .background(model.pageID == page.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityIdentifier("diagram.page.\(page.id)")
                .accessibilityAddTraits(model.pageID == page.id ? .isSelected : [])
                .contextMenu { pageActions(page) }
            }
        }
    }
    private func pageMenu(showTitle: Bool) -> some View {
        Menu {
            Picker(DL("页面", "Pages"), selection: pageSelection) {
                ForEach(model.document.pages) { page in Text(page.title).tag(page.id) }
            }.pickerStyle(.inline)
            Divider()
            pageActions(model.page)
            Divider()
            Label("\(model.page.elements.count) "+DL("个主题与图形", "topics & shapes"), systemImage: "square.stack.3d.up")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                if showTitle {
                    Text(model.page.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(showTitle ? model.page.title : DL("页面", "Pages"))
        .accessibilityValue("\((model.document.pages.firstIndex { $0.id == model.pageID } ?? 0)+1) / \(model.document.pages.count)")
        .accessibilityIdentifier("diagram.pageMenu")
        .help(DL("页面", "Pages"))
    }
    @ViewBuilder private func pageActions(_ page: DiagramPage) -> some View {
        Button(DL("重命名页面", "Rename page"), systemImage: "pencil") { model.selectPage(page.id); renamePage() }
        Button(DL("复制页面", "Duplicate page"), systemImage: "doc.on.doc") { model.selectPage(page.id); model.duplicatePage() }
        Button(DL("前移", "Move earlier"), systemImage: "arrow.left") { model.selectPage(page.id); model.movePage(by: -1) }
        Button(DL("后移", "Move later"), systemImage: "arrow.right") { model.selectPage(page.id); model.movePage(by: 1) }
        Button(DL("删除页面", "Delete page"), systemImage: "trash", role: .destructive) { model.selectPage(page.id); model.deletePage() }.disabled(model.document.pages.count == 1)
    }
}
#endif
