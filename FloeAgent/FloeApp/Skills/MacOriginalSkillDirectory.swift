#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeSkills

struct MacOriginalSkillDirectory: View {
    let installedOnly: Bool
    let query: String
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var center = MacOriginalSkillsCenter.shared
    @ObservedObject private var bridge = MacBridgeConnectionCenter.shared
    @State private var selected: MacOriginalSkillCatalog.Entry?
    private var items: [SkillHubDisplayItem] {
        center.entries.filter { !installedOnly || center.installed[$0.id] != nil }.map { entry in
            let current = center.installed[entry.id]
            let action: SkillHubDisplayItem.Action = if let current {
                current["digest"]?.string == entry.digest ? (center.isEnabled(entry.id) ? .added : .enable) : .update
            } else { .get }
            return SkillHubDisplayItem(id: entry.id,
                title: entry.name.value(preferredLanguages: Locale.preferredLanguages),
                summary: entry.description.value(preferredLanguages: Locale.preferredLanguages),
                category: Self.category(entry.category), systemImage: "terminal", action: action,
                actionEnabled: bridge.connected && center.jobs[entry.id] == nil && MacOriginalSkillCatalog.compatible(entry,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error = center.error {
                HStack { Text(error).font(.caption).foregroundStyle(.secondary); Spacer()
                    Button("action.retry") { Task { await center.refresh(using: environment) } }.disabled(center.refreshing)
                }.padding(.horizontal).padding(.vertical, 8)
            }
            if !bridge.connected {
                HStack { Text("mac.bridge.disconnected"); Spacer(); Button("mac.bridge.reconnect") { bridge.connect() } }
                    .font(.subheadline).padding()
            }
            SkillHubDiscoveryView(items: items, query: query,
                onSelect: { id in selected = center.entries.first { $0.id == id } },
                onGet: perform, connections: { EmptyView() })
            if installedOnly {
                let visible = Set(center.entries.map(\.id))
                let archived = center.installed.keys.filter { !visible.contains($0) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }.sorted()
                if !archived.isEmpty {
                    List {
                        Section("mac.skills.other_installed") {
                            ForEach(archived, id: \.self) { id in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(id)
                                        Text(center.installed[id]?["version"]?.string ?? "").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Toggle("plugins.enabled", isOn: Binding(get: { center.isEnabled(id) }, set: { center.setEnabled($0, id: id) })).labelsHidden()
                                    Button("action.delete", role: .destructive) { Task { await center.remove(id) } }.disabled(!bridge.connected)
                                }
                            }
                        }
                    }.frame(minHeight: 120)
                }
            }
            if !center.jobs.isEmpty {
                VStack(spacing: 6) {
                    ForEach(center.jobs.keys.sorted(), id: \.self) { id in
                        if let job = center.jobs[id] {
                            HStack {
                                Text(job.stage).font(.caption)
                                ProgressView(value: Double(job.completed), total: Double(max(1, job.total)))
                                Text("\(job.completed)/\(job.total)").font(.caption.monospacedDigit())
                                Button("action.cancel") { center.cancel(id) }
                            }
                        }
                    }
                }.padding().background(.bar)
            }
        }
        .task { await center.refresh(using: environment) }
        .navigationDestination(item: $selected) { entry in MacOriginalSkillDetail(entry: entry) }
    }
    private func perform(_ id: String) {
        guard let entry = center.entries.first(where: { $0.id == id }) else { return }
        selected = entry
        if center.installed[id] != nil, !center.isEnabled(id) { center.setEnabled(true, id: id) }
        else { center.install(entry, using: environment) }
    }
    static func category(_ category: CuratedSkillCategory) -> SkillHubCategory {
        switch category {
        case .officeDocuments: .office
        case .writingCommunication: .writing
        case .webDevelopment: .development
        case .researchData: .research
        case .designCreation: .design
        case .productRequirements: .product
        case .productivityOrganization: .productivity
        }
    }
}

private struct MacOriginalSkillDetail: View {
    let entry: MacOriginalSkillCatalog.Entry
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var center = MacOriginalSkillsCenter.shared
    @ObservedObject private var bridge = MacBridgeConnectionCenter.shared
    @State private var confirmsRemove = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(MacOriginalSkillDirectory.category(entry.category).artworkName)
                    .resizable().aspectRatio(16 / 9, contentMode: .fill).clipped()
                    .accessibilityHidden(true)
                Text(entry.name.value(preferredLanguages: Locale.preferredLanguages)).font(.title.bold())
                Text(entry.description.value(preferredLanguages: Locale.preferredLanguages))
                if center.installed[entry.id] != nil {
                    Toggle("plugins.enabled", isOn: Binding(get: { center.isEnabled(entry.id) }, set: { center.setEnabled($0, id: entry.id) }))
                    if center.installed[entry.id]?["digest"]?.string != entry.digest {
                        Button("skills.update.now") { center.install(entry, using: environment) }.buttonStyle(.borderedProminent).disabled(!bridge.connected)
                    }
                    Button("action.delete", role: .destructive) { confirmsRemove = true }.disabled(!bridge.connected)
                } else {
                    Button("skills.hub.get") { center.install(entry, using: environment) }
                        .buttonStyle(.borderedProminent).disabled(!bridge.connected || center.jobs[entry.id] != nil)
                }
                if let job = center.jobs[entry.id] {
                    ProgressView(job.stage, value: Double(job.completed), total: Double(max(job.total, 1)))
                    Button("action.cancel") { center.cancel(entry.id) }
                }
                GroupBox {
                    LabeledContent("mac.skills.variant", value: String(localized: "mac.skills.original"))
                    LabeledContent("skills.version", value: entry.version)
                    LabeledContent("mac.skills.source", value: entry.repository)
                    LabeledContent("mac.skills.license", value: entry.license)
                }
                if let error = center.error { Text(error).foregroundStyle(.red) }
            }.padding().frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .navigationTitle(entry.name.value(preferredLanguages: Locale.preferredLanguages))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("skills.remove.title", isPresented: $confirmsRemove) {
            Button("action.delete", role: .destructive) { Task { await center.remove(entry.id) } }
        }
    }
}
#endif
