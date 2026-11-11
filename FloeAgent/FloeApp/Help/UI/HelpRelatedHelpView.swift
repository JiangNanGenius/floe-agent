// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct HelpRelatedHelpDocument {
    let snapshot: HelpLibrarySnapshot
    let article: HelpArticle
    let reference: HelpReference
    let title: String
    let excerpt: String

    @MainActor
    init(center: HelpContentCenter, reference: HelpReference) throws {
        let snapshot = try center.snapshot(for: reference)
        guard let article = snapshot.article(id: reference.articleID) else { throw HelpContentError.unavailable }
        let read = try snapshot.read(reference, maximumCharacters: 1200)
        self.snapshot = snapshot; self.article = article; self.reference = reference
        title = read.sectionTitle ?? article.title
        let lines = read.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != read.articleTitle && $0 != read.sectionTitle }
        excerpt = String(lines.prefix(6).joined(separator: "\n\n").prefix(900))
    }

    var settingsTargets: [HelpSettingsTarget] {
        article.settingIDs.compactMap { HelpSettingsCatalog.target(id: $0, language: reference.language) }
    }
}

struct HelpRelatedHelpView: View {
    let center: HelpContentCenter
    let reference: HelpReference
    let onOpenSettings: (HelpSettingsTarget) -> Void
    @State private var document: HelpRelatedHelpDocument?
    @State private var failed = false

    private var copy: HelpCopy { .init(language: reference.language) }

    var body: some View {
        Group {
            if let document {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(document.title).font(.title2.weight(.semibold))
                        ForEach(document.settingsTargets) { target in
                            Text(target.path.joined(separator: " › "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !document.excerpt.isEmpty {
                            Text(document.excerpt).font(.body).lineLimit(10).textSelection(.enabled)
                        }
                        ForEach(document.settingsTargets) { target in
                            Button { onOpenSettings(target) } label: {
                                Text(copy.openSetting).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityIdentifier("help.related.openSetting.\(target.id)")
                        }
                        NavigationLink {
                            HelpArticleView(center: center, reference: reference, frozenSnapshot: document.snapshot,
                                            onOpenSettings: onOpenSettings)
                        } label: {
                            Text(copy.readFullChapter).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityIdentifier("help.related.readFullChapter")
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if failed {
                ContentUnavailableView(copy.unavailable, systemImage: "book.closed",
                                       description: Text(copy.unavailableDetail))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(copy.relatedHelp)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reference) {
            await center.prepare()
            guard !Task.isCancelled else { return }
            do { document = try HelpRelatedHelpDocument(center: center, reference: reference); failed = false }
            catch { failed = true }
        }
        .accessibilityIdentifier("help.related")
    }
}
#endif
