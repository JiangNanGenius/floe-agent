#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloePersistence

/// One scene-level presenter shared by Hub and Task Center.
struct SkillAuthoringPresentationHost: ViewModifier {
    @ObservedObject var coordinator: SkillAuthoringCoordinator
    @ObservedObject var router: AppRouter

    func body(content: Content) -> some View {
        content.sheet(item: $coordinator.presentation) { value in
            SkillAuthoringView(coordinator: coordinator, id: value.id, openTask: { id in
                coordinator.presentation = nil
                router.openConversation(id)
            })
        }
        .alert(FloeL10n.l("skills.authoring.error.open"), isPresented: Binding(
            get: { coordinator.entryError != nil },
            set: { if !$0 { coordinator.entryError = nil } }
        )) {
            Button(FloeL10n.l("skills.authoring.dismiss"), role: .cancel) { coordinator.entryError = nil }
        } message: { Text(coordinator.entryError ?? "") }
    }
}

/// Both Hub and Task Center open this same panel; dismissal shelves work.
struct SkillAuthoringView: View {
    @ObservedObject var coordinator: SkillAuthoringCoordinator
    let id: UUID
    var openTask: (UUID) -> Void = { _ in }
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFolder = false
    @State private var review: SkillAuthoringPackageDescriptor?

    var body: some View {
        NavigationStack {
            Form {
                if let record = coordinator.record(id) {
                    Section {
                        LabeledContent(FloeL10n.l("skills.authoring.status"), value: FloeL10n.l(record.phase.titleKey))
                        if coordinator.isWorking(id) { ProgressView() }
                        if let question = coordinator.questions[id] { Text(question).textSelection(.enabled) }
                        if let error = coordinator.errors[id] ?? record.failureMessage {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                    if !record.isPromoted, ![.installed, .cancelling].contains(record.phase) {
                        Section {
                            TextEditor(text: Binding(get: { coordinator.draftText(id) },
                                set: { coordinator.updateDraft(id: id, text: $0) }))
                                .frame(minHeight: 130)
                                .disabled(coordinator.isWorking(id))
                            LabeledContent(FloeL10n.l("skills.authoring.model"), value: coordinator.modelLabel(id))
                            if [.draft, .failed, .interrupted, .stopped].contains(record.phase), record.kind == .importing {
                                Button(FloeL10n.l("skills.authoring.choose_folder"), systemImage: "folder") { choosingFolder = true }
                                Button(FloeL10n.l("skills.authoring.import_url"), systemImage: "link") { coordinator.importURL(id: id) }
                                    .disabled(coordinator.isWorking(id) || coordinator.draftText(id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            if [.draft, .failed, .interrupted, .stopped, .needsUser].contains(record.phase),
                               record.kind == .creation || record.phase == .needsUser {
                                Button(FloeL10n.l("skills.authoring.generate")) { coordinator.generate(id: id) }
                                    .disabled(coordinator.isWorking(id) || coordinator.draftText(id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                    if let package = coordinator.packages[id] {
                        Section {
                            Text(package.title).font(.headline)
                            if !package.summary.isEmpty { Text(package.summary) }
                            DisclosureGroup(FloeL10n.l("skills.authoring.files")) {
                                ForEach(package.fileNames, id: \.self) { Text($0).font(.footnote) }
                            }
                            if record.phase == .ready {
                                Button(FloeL10n.l("skills.authoring.add")) { review = package }
                                    .disabled(coordinator.adding.contains(id))
                                Button(FloeL10n.l("skills.authoring.adapt")) { coordinator.generate(id: id, adapting: true) }
                                    .disabled(coordinator.isWorking(id) || coordinator.adding.contains(id))
                            }
                        }
                    }
                    if !record.phase.isSettled, !record.isPromoted {
                        Section { Button(FloeL10n.l("skills.authoring.cancel"), role: .destructive) {
                            Task { await coordinator.cancel(id: id) }
                        }.disabled(record.phase == .cancelling) }
                    }
                    if record.isPromoted {
                        Button(FloeL10n.l("skills.authoring.open_task")) { coordinator.close(id: id); openTask(id) }
                    } else if record.phase.isSettled {
                        Button(FloeL10n.l("skills.authoring.done")) { Task { await coordinator.acknowledge(id: id) } }
                    }
                }
            }
            .navigationTitle(FloeL10n.l(coordinator.record(id)?.kind.titleKey ?? "skills.authoring.create"))
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(FloeL10n.l("skills.authoring.close")) { coordinator.close(id: id) }
            } }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): coordinator.importFolder(id: id, url: url)
                case .failure(let error): if !(error is CancellationError) { coordinator.entryError = FloeL10n.l("skills.authoring.error.source") }
                }
            }
            .sheet(item: $review) { package in
                NavigationStack {
                    Form {
                        Section { Text(package.title).font(.headline); Text(package.summary) }
                        Section(FloeL10n.l("skills.authoring.permissions")) {
                            if package.manifest.capabilities.isEmpty { Text(FloeL10n.l("skills.authoring.none")) }
                            ForEach(package.manifest.capabilities, id: \.self) { Text($0) }
                        }
                        Section(FloeL10n.l("skills.authoring.tools")) {
                            if package.manifest.tools.isEmpty { Text(FloeL10n.l("skills.authoring.none")) }
                            ForEach(package.manifest.tools, id: \.self) { Text($0) }
                        }
                        Section(FloeL10n.l("skills.authoring.scripts")) {
                            let scripts = package.fileNames.filter { $0.hasPrefix("scripts/") }
                            if scripts.isEmpty { Text(FloeL10n.l("skills.authoring.none")) }
                            ForEach(scripts, id: \.self) { Text($0) }
                        }
                        Button(FloeL10n.l("skills.authoring.add")) {
                            review = nil
                            Task { await coordinator.add(id: id, reviewedSnapshotID: package.snapshotID, reviewedDigest: package.digest) }
                        }
                    }
                    .navigationTitle(FloeL10n.l("skills.authoring.review"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button(FloeL10n.l("skills.authoring.close")) { review = nil }
                    } }
                }
            }
            .alert(FloeL10n.l("skills.authoring.advisory.title"), isPresented: Binding(
                get: { coordinator.advisory?.id == id }, set: { _ in })) {
                Button(FloeL10n.l("skills.authoring.keep_waiting"), role: .cancel) {
                    Task { _ = await coordinator.answerAdvisory(id: id, convert: false) }
                }
                Button(FloeL10n.l("skills.authoring.convert")) {
                    Task {
                        if await coordinator.answerAdvisory(id: id, convert: true), coordinator.isPanelVisible(id) {
                            coordinator.close(id: id); openTask(id)
                        }
                    }
                }
            } message: { Text(FloeL10n.l("skills.authoring.advisory.body")) }
        }
        .onAppear { coordinator.panelVisibility(id: id, visible: true) }
        .onDisappear { coordinator.panelVisibility(id: id, visible: false) }
        .onChange(of: scenePhase) { _, phase in
            coordinator.panelVisibility(id: id, visible: phase == .active)
        }
    }
}

extension SkillAuthoringPackageDescriptor: Identifiable { var id: UUID { snapshotID } }

/// Reusable projection; the embedding screen owns navigation and placement.
struct SkillAuthoringRows: View {
    @ObservedObject var coordinator: SkillAuthoringCoordinator
    var taskCenter = false
    var body: some View {
        ForEach(taskCenter ? coordinator.taskCenterRecords : coordinator.shelfRecords) { record in
            Button { Task { await coordinator.open(id: record.id) } } label: {
                HStack {
                    Image(systemName: record.kind == .creation ? "sparkles" : "square.and.arrow.down")
                    Text(FloeL10n.l(record.kind.titleKey))
                    Spacer()
                    Text(FloeL10n.l(record.phase.titleKey)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
