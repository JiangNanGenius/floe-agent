// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import SwiftUI
import UIKit
import FloeCore

struct HelpArticleDocument {
    let snapshot: HelpLibrarySnapshot
    let article: HelpArticle
    let reference: HelpReference

    var plainText: String {
        ([article.title] + article.sections.flatMap { [$0.title, $0.text] })
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

enum HelpReaderAppearance: String, CaseIterable {
    case system, light, dark
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

private enum HelpReaderPanel: String, Identifiable {
    case contents, information
    var id: String { rawValue }
}

struct HelpArticleView: View {
    @ObservedObject var center: HelpContentCenter
    let reference: HelpReference
    var onOpenSettings: ((HelpSettingsTarget) -> Void)?
    private let frozenSnapshot: HelpLibrarySnapshot?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .body) private var bodyPointSize = 17.0
    @AppStorage("floe.help.reader.appearance") private var appearanceValue = HelpReaderAppearance.system.rawValue
    @AppStorage("floe.help.reader.textScale") private var textScale = 1.0
    @StateObject private var reader = HelpWebReaderController()
    @State private var document: HelpArticleDocument?
    @State private var failed = false
    @State private var panel: HelpReaderPanel?
    @State private var image: HelpReaderImage?
    @State private var linkedReference: HelpReference?
    @State private var copied = false

    init(center: HelpContentCenter, reference: HelpReference,
         frozenSnapshot: HelpLibrarySnapshot? = nil,
         onOpenSettings: ((HelpSettingsTarget) -> Void)? = nil) {
        self.center = center
        self.reference = reference
        self.frozenSnapshot = frozenSnapshot
        self.onOpenSettings = onOpenSettings
    }

    private var copy: HelpCopy { .init(language: reference.language) }
    private var appearance: HelpReaderAppearance { HelpReaderAppearance(rawValue: appearanceValue) ?? .system }

    var body: some View {
        Group {
            if let document {
                VStack(spacing: 0) {
                    if let onOpenSettings {
                        let targets = document.article.settingIDs.compactMap {
                            HelpSettingsCatalog.target(id: $0, language: reference.language)
                        }
                        if !targets.isEmpty {
                            HelpRelatedSettingsBar(targets: targets, copy: copy, onOpen: onOpenSettings)
                            Divider()
                        }
                    }
                    HelpArticleWebView(document: document, controller: reader,
                                       pointSize: bodyPointSize * min(max(textScale, 0.8), 1.8),
                                       dark: (appearance.colorScheme ?? colorScheme) == .dark,
                                       imageLabel: copy.enlargeImage,
                                       onReference: { linkedReference = $0 },
                                       onImage: { image = $0 },
                                       onFailure: { failed = true; self.document = nil },
                                       onExternalURL: { openURL($0) })
                        .accessibilityIdentifier("help.article.body")
                }
            } else if failed {
                ContentUnavailableView(copy.unavailable, systemImage: "book.closed",
                                       description: Text(copy.unavailableDetail))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(document?.article.title ?? copy.title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(appearance.colorScheme)
        .toolbar { readerToolbar }
        .task(id: reference) {
            await center.prepare()
            guard !Task.isCancelled else { return }
            load()
        }
        .sheet(item: $panel) { selectedPanel in
            NavigationStack {
                switch selectedPanel {
                case .contents:
                    HelpContentsView(sections: document?.article.sections ?? [], copy: copy) { section in
                        reader.scroll(to: section.id)
                    }
                case .information:
                    HelpDocumentInformationView(document: document, copy: copy)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $image) { item in
            HelpImageZoomView(item: item, copy: copy)
        }
        .navigationDestination(item: $linkedReference) { next in
            HelpArticleView(center: center, reference: next, frozenSnapshot: document?.snapshot,
                            onOpenSettings: onOpenSettings)
        }
        .accessibilityIdentifier("help.article.\(reference.articleID)")
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { panel = .contents } label: {
                Label(copy.contents, systemImage: "list.bullet")
            }
            .disabled(document == nil)
            .accessibilityIdentifier("help.article.contents")
            Button { reader.showFind() } label: {
                Label(copy.find, systemImage: "magnifyingglass")
            }
            .disabled(document == nil)
            .accessibilityIdentifier("help.article.find")
            Menu {
                Button {
                    guard let document else { return }
                    UIPasteboard.general.string = document.plainText
                    copied = true
                } label: {
                    Label(copied ? copy.copied : copy.copy, systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Section(copy.reading) {
                    Picker(copy.appearance, selection: $appearanceValue) {
                        Text(copy.system).tag(HelpReaderAppearance.system.rawValue)
                        Text(copy.light).tag(HelpReaderAppearance.light.rawValue)
                        Text(copy.dark).tag(HelpReaderAppearance.dark.rawValue)
                    }
                    ControlGroup {
                        Button { textScale = max(0.8, textScale - 0.1) } label: {
                            Label(copy.textSize + " −", systemImage: "textformat.size.smaller")
                        }.disabled(textScale <= 0.8)
                        Button { textScale = min(1.8, textScale + 0.1) } label: {
                            Label(copy.textSize + " +", systemImage: "textformat.size.larger")
                        }.disabled(textScale >= 1.8)
                    }
                }
                Button { panel = .information } label: {
                    Label(copy.info, systemImage: "info.circle")
                }
            } label: {
                Label(copy.reading, systemImage: "textformat")
            }
            .disabled(document == nil)
            .accessibilityIdentifier("help.article.options")
        }
    }

    private func load() {
        guard document?.reference != reference else { return }
        do {
            let snapshot: HelpLibrarySnapshot
            if let frozenSnapshot, frozenSnapshot.manifest.id == reference.packageID,
               frozenSnapshot.manifest.version == reference.version, frozenSnapshot.index.locale == reference.language {
                snapshot = frozenSnapshot
            } else {
                snapshot = try center.snapshot(for: reference)
            }
            // Resolve the exact chapter as well as the article before loading WebKit.
            _ = try snapshot.reference(articleID: reference.articleID, sectionID: reference.sectionID)
            guard let article = snapshot.article(id: reference.articleID) else {
                failed = true; document = nil; return
            }
            document = HelpArticleDocument(snapshot: snapshot, article: article, reference: reference)
            failed = false
        } catch {
            failed = true
            document = nil
        }
    }
}

private struct HelpRelatedSettingsBar: View {
    let targets: [HelpSettingsTarget]
    let copy: HelpCopy
    let onOpen: (HelpSettingsTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(targets) { target in
                Button { onOpen(target) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.path.joined(separator: " › "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(copy.openSetting).font(.subheadline.weight(.semibold))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tint(.accentColor)
                .accessibilityIdentifier("help.openSetting.\(target.id)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct HelpContentsView: View {
    @Environment(\.dismiss) private var dismiss
    let sections: [HelpSection]
    let copy: HelpCopy
    let onSelect: (HelpSection) -> Void

    var body: some View {
        List(sections) { section in
            Button {
                onSelect(section)
                dismiss()
            } label: {
                Text(section.title)
                    .foregroundStyle(.primary)
                    .padding(.leading, CGFloat(max(0, section.level - 1)) * 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 36, alignment: .leading)
            }
        }
        .navigationTitle(copy.contents)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(copy.done) { dismiss() } } }
    }
}

private struct HelpDocumentInformationView: View {
    @Environment(\.dismiss) private var dismiss
    let document: HelpArticleDocument?
    let copy: HelpCopy

    var body: some View {
        Form {
            if let document {
                LabeledContent(copy.version, value: document.reference.version)
                LabeledContent(copy.languageLabel, value: document.reference.language == .english ? "English" : "简体中文")
                Section(copy.source) {
                    Text(document.snapshot.manifest.sourceRevision).textSelection(.enabled)
                }
            }
        }
        .navigationTitle(copy.info)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(copy.done) { dismiss() } } }
    }
}
#endif
