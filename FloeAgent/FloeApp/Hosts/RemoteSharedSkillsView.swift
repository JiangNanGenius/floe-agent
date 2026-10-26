#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeSSH
import FloeExecution

struct RemoteSharedSkillsView: View {
    let host: RemoteHostProfile
    @ObservedObject var center: RemoteSessionCenter
    @State private var skills: [RemoteSharedSkill] = []
    @State private var loading = false
    @State private var unsupported = false
    @State private var error: String?
    @State private var adding = false
    @State private var generation = UUID()
    private var service: RemoteSharedSkillsService {
        RemoteSharedSkillsService(client: center.environment.cloudWorkspaceService)
    }

    var body: some View {
        List {
            if unsupported {
                Section {
                    Button("remote.skills.update_service") {
                        Task {
                            loading = true
                            do { _ = try await center.updateRemoteAgent(on: host); await reload() }
                            catch { self.error = FloeL10n.l("remote.skills.connection_failed"); loading = false }
                        }
                    }.disabled(loading)
                }
            } else if skills.isEmpty, !loading, error == nil {
                ContentUnavailableView("remote.skills.empty", systemImage: "puzzlepiece.extension")
            }
            ForEach(skills) { skill in
                NavigationLink {
                    RemoteSharedSkillDetail(hostID: host.id, skill: skill, service: service)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.name).font(.headline)
                        Text(skill.repository).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .swipeActions {
                    Button("skills.update.now") { Task { await update(skill) } }
                        .disabled(loading)
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("action.retry") { Task { await reload() } }.disabled(loading)
                }
            }
        }
        .navigationTitle("remote.skills.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("skills.hub.add", systemImage: "plus") { adding = true }
                    .disabled(loading || unsupported || error != nil)
            }
        }
        .overlay { if loading && skills.isEmpty { ProgressView() } }
        .refreshable { await reload() }
        .task { await reload() }
        .onDisappear { generation = UUID() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                RemoteSharedSkillAdd(hostID: host.id, service: service, center: center) { Task { await reload() } }
            }
        }
    }

    private func reload() async {
        let request = UUID(); generation = request
        loading = true
        do {
            let result = try await service.list(hostID: host.id)
            guard generation == request, !Task.isCancelled else { return }
            skills = result; unsupported = false; error = nil
        } catch RemoteSharedSkillsError.updateRequired {
            guard generation == request else { return }
            unsupported = true; error = nil
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            self.error = FloeL10n.l("remote.skills.connection_failed")
        }
        if generation == request { loading = false }
    }

    private func update(_ skill: RemoteSharedSkill) async {
        guard !loading else { return }
        loading = true
        do {
            _ = try await service.pull(hostID: host.id, id: skill.id, repository: skill.repository,
                ref: skill.ref, subdirectory: skill.subdirectory)
            await reload()
        } catch {
            self.error = FloeL10n.l("remote.skills.pull_failed"); loading = false
        }
    }
}

private struct RemoteSharedSkillAdd: View {
    let hostID: UUID
    let service: RemoteSharedSkillsService
    @ObservedObject var center: RemoteSessionCenter
    let onInstalled: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var ref = ""
    @State private var subdirectory = ""
    @State private var installing = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("remote.skills.repository", text: $repository).keyboardType(.URL)
                TextField("remote.skills.ref", text: $ref)
                TextField("remote.skills.directory", text: $subdirectory)
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("remote.skills.add")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.cancel") { dismiss() }.disabled(installing)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("action.install") {
                    installing = true
                    let repo = repository.trimmingCharacters(in: .whitespacesAndNewlines)
                    let path = subdirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sourceRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
                    let id = "skill-" + String(FloeDigest.sha256Hex(Data((repo + "\n" + path).utf8)).prefix(20))
                    Task {
                        do {
                            _ = try await service.pull(hostID: hostID, id: id, repository: repo,
                                ref: sourceRef.isEmpty ? "HEAD" : sourceRef, subdirectory: path)
                            onInstalled(); dismiss()
                        } catch { self.error = FloeL10n.l("remote.skills.pull_failed"); installing = false }
                    }
                }.disabled(repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || installing)
            }
        }
        .interactiveDismissDisabled(installing)
        .sheet(item: Binding(get: { center.pendingTrust }, set: { _ in })) { trust in
            HostKeyTrustSheet(challenge: trust.challenge) { center.resolveTrust($0) }
        }
    }
}

private struct RemoteSharedSkillDetail: View {
    let hostID: UUID
    let skill: RemoteSharedSkill
    let service: RemoteSharedSkillsService
    @State private var document: RemoteSharedSkillDocument?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if let version = skill.version { LabeledContent("skills.update.installed", value: version) }
                LabeledContent("remote.skills.ref", value: skill.ref)
                LabeledContent("remote.skills.revision", value: String(skill.revision.prefix(12)))
                Text(skill.containerPath).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let document {
                Section { MarkdownRendererView(source: document.content, isStreaming: false) }
            } else if let error { Text(error).foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .navigationTitle(skill.name)
        .task(id: skill.digest) {
            do {
                let value = try await service.read(hostID: hostID, skill: skill)
                guard !Task.isCancelled else { return }
                document = value; error = nil
            } catch { if !Task.isCancelled { self.error = FloeL10n.l("remote.skills.connection_failed") } }
        }
    }
}
#endif
