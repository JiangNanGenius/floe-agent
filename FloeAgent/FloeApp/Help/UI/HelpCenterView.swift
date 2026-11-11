// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// Lives in the settings detail navigation stack; it never owns another split view.
struct HelpCenterView: View {
    @ObservedObject var center: HelpContentCenter
    let language: HelpLanguage
    var onOpenSettings: ((HelpSettingsTarget) -> Void)?
    @State private var selectedLanguage: HelpLanguage
    @State private var query = ""
    @State private var snapshot: HelpLibrarySnapshot?
    @State private var failed = false

    init(center: HelpContentCenter, language: HelpLanguage,
         onOpenSettings: ((HelpSettingsTarget) -> Void)? = nil) {
        self.center = center
        self.language = language
        self.onOpenSettings = onOpenSettings
        _selectedLanguage = State(initialValue: language)
    }

    private var copy: HelpCopy { .init(language: selectedLanguage) }
    private var searchQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Group {
            if let snapshot {
                List {
                    if searchQuery.isEmpty {
                        ForEach(snapshot.index.categories) { category in
                            Section(category.title) {
                                ForEach(category.entries) { entry in
                                    if let reference = try? snapshot.reference(articleID: entry.articleID, sectionID: entry.sectionID) {
                                        NavigationLink(value: reference) {
                                            HelpTopicRow(title: entry.title, summary: entry.summary,
                                                         systemImage: topicImage(category.id))
                                        }
                                        .accessibilityIdentifier("help.topic.\(entry.id)")
                                    }
                                }
                            }
                        }
                        Section {
                            Label(copy.offline, systemImage: "book.closed")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .listRowBackground(Color.clear)
                        }
                    } else {
                        let hits = snapshot.search(searchQuery, limit: 24)
                        if hits.isEmpty {
                            ContentUnavailableView(copy.noResults, systemImage: "magnifyingglass",
                                                   description: Text(copy.trySearch))
                                .listRowBackground(Color.clear)
                        } else {
                            Section(copy.searchResults) {
                                ForEach(hits) { hit in
                                    NavigationLink(value: hit.reference) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(hit.sectionTitle ?? hit.articleTitle)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                                .fixedSize(horizontal: false, vertical: true)
                                            if hit.sectionTitle != nil {
                                                Text(hit.articleTitle).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Text(hit.snippet)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(3)
                                        }
                                        .padding(.vertical, 3)
                                    }
                                    .accessibilityIdentifier("help.search.\(hit.id)")
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else if failed {
                ContentUnavailableView {
                    Label(copy.unavailable, systemImage: "book.closed")
                } description: {
                    Text(copy.unavailableDetail)
                } actions: {
                    Button(copy.retry) { load() }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(copy.title)
        .searchable(text: $query, prompt: copy.search)
        .navigationDestination(for: HelpReference.self) { reference in
            HelpArticleView(center: center, reference: reference, frozenSnapshot: snapshot,
                            onOpenSettings: onOpenSettings)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(copy.languageLabel, selection: $selectedLanguage) {
                        Text("English").tag(HelpLanguage.english)
                        Text("简体中文").tag(HelpLanguage.simplifiedChinese)
                    }
                } label: {
                    Label(copy.languageLabel, systemImage: "character.bubble")
                }
                .accessibilityIdentifier("help.language")
            }
        }
        .task(id: "\(selectedLanguage.rawValue):\(center.revision)") {
            await center.prepare()
            guard !Task.isCancelled else { return }
            load()
        }
        .onChange(of: language) { _, newValue in selectedLanguage = newValue }
        .accessibilityIdentifier("help.center")
    }

    private func load() {
        do {
            snapshot = try center.snapshot(language: selectedLanguage)
            failed = false
        } catch {
            snapshot = nil
            failed = true
        }
    }

    private func topicImage(_ categoryID: String) -> String {
        switch categoryID {
        case "getting-started", "quickstart", "start": "bolt"
        case "models", "settings", "models-settings": "gearshape"
        case "tasks", "permissions", "tasks-permissions": "checklist"
        case "notes", "files", "notes-files": "doc.text"
        case "workspaces", "creative", "space": "pencil.and.outline"
        case "connections", "development": "chevron.left.forwardslash.chevron.right"
        case "faq": "questionmark.bubble"
        default: "book"
        }
    }
}

private struct HelpTopicRow: View {
    let title: String
    let summary: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
                .frame(minHeight: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary)
                if !summary.isEmpty {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }
}
#endif
