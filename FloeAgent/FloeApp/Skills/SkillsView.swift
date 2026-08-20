#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence

struct SkillsView: View {
    @ObservedObject var center: SkillsCenter
    @State private var showingCreator = false
    @State private var showingFinder = false
    @State private var pendingRemoval: PersistedSkill?

    var body: some View {
        List {
            if center.installed.isEmpty {
                ContentUnavailableView("skills.empty", systemImage: "puzzlepiece.extension")
            } else {
                ForEach(center.installed) { skill in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(skill.name).font(.headline)
                                Text("v\(skill.version)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("skills.enabled", isOn: Binding(
                                get: { skill.status == "enabled" },
                                set: { value in Task { await center.setEnabled(value, skill: skill) } }
                            )).labelsHidden()
                        }
                        Text(skill.skillMarkdown.split(separator: "\n").dropFirst(4).joined(separator: "\n"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    .swipeActions {
                        Button("action.delete", role: .destructive) { pendingRemoval = skill }
                    }
                }
            }
            if let error = center.errorMessage {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        }
        .overlay { if center.isWorking { ProgressView().controlSize(.large) } }
        .navigationTitle("skills.title")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("skills.finder", systemImage: "magnifyingglass") { showingFinder = true }
                Button("skills.creator", systemImage: "plus") { showingCreator = true }
            }
        }
        .task { await center.load() }
        .sheet(isPresented: $showingCreator) { SkillCreatorSheet(center: center) }
        .sheet(isPresented: $showingFinder) { SkillFinderSheet(center: center) }
        .sheet(item: $center.pendingInstallation) { pending in
            SkillInstallReviewSheet(center: center, pending: pending)
        }
        .alert("skills.remove.title", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("action.cancel", role: .cancel) { pendingRemoval = nil }
            Button("action.delete", role: .destructive) {
                if let skill = pendingRemoval { Task { await center.remove(skill) } }
                pendingRemoval = nil
            }
        }
    }
}

private struct SkillInstallReviewSheet: View {
    @ObservedObject var center: SkillsCenter
    let pending: SkillsCenter.PendingInstallation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("skills.review.source") { Text(pending.sourceURL.absoluteString).font(.footnote) }
                Section("skills.review.permissions") {
                    if pending.capabilityNames.isEmpty { Text("skills.review.none") }
                    ForEach(pending.capabilityNames, id: \.self) { Text($0) }
                }
                if !pending.toolNames.isEmpty {
                    Section("skills.review.tools") { ForEach(pending.toolNames, id: \.self) { Text($0) } }
                }
                if pending.containsScripts {
                    Label("skills.review.scripts", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("skills.review.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { center.cancelPendingInstallation(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.install") { Task { await center.confirmPendingInstallation(); dismiss() } }
                }
            }
        }
    }
}

private struct SkillCreatorSheet: View {
    @ObservedObject var center: SkillsCenter
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("skills.name", text: $name)
                TextField("skills.description", text: $description, axis: .vertical)
                TextField("skills.instructions", text: $instructions, axis: .vertical).lineLimit(6...14)
            }
            .navigationTitle("skills.creator")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.install") {
                        Task { await center.create(name: name, description: description, instructions: instructions); if center.errorMessage == nil { dismiss() } }
                    }.disabled(name.isEmpty || description.isEmpty || instructions.isEmpty || center.isWorking)
                }
            }
        }
    }
}

private struct SkillFinderSheet: View {
    @ObservedObject var center: SkillsCenter
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var rewriteModelID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("skills.finder.source")
                } footer: {
                    Text("skills.finder.footer")
                }
                Picker("skills.finder.model", selection: $rewriteModelID) {
                    ForEach(center.rewriteModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
            }
            .navigationTitle("skills.finder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.install") {
                        Task { await center.installFromFinder(urlText: url, rewriteModelID: rewriteModelID); if center.errorMessage == nil { dismiss() } }
                    }.disabled(url.isEmpty || rewriteModelID == nil || center.isWorking)
                }
            }
            .onAppear { if rewriteModelID == nil { rewriteModelID = center.defaultRewriteModelID ?? center.rewriteModels.first?.id } }
        }
    }
}
#endif
