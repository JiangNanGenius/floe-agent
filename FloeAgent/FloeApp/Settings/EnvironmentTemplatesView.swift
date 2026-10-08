// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeTools

/// Template prepare/create jobs survive navigation: the service owns the
/// task lifetime, this object only mirrors its progress for the UI.
@MainActor final class EnvironmentTemplateJobs: ObservableObject {
    static let shared = EnvironmentTemplateJobs()
    @Published private(set) var preparing: Set<String> = []
    @Published private(set) var creating: Set<String> = []
    @Published private(set) var messages: [String: String] = [:]
    @Published private(set) var failures: Set<String> = []
    @Published private(set) var fractions: [String: Double] = [:]
    @Published private(set) var revision = 0
    private var prepareTasks: [String: Task<Void, Never>] = [:]

    func prepare(templateID: String) {
        guard !preparing.contains(templateID) else { return }
        preparing.insert(templateID)
        failures.remove(templateID)
        fractions[templateID] = nil
        messages[templateID] = String(localized: "template.downloading_verifying_image")
        prepareTasks[templateID] = Task {
            do {
                _ = try await FloePlatformServices.shared.prepareOfficialTemplate(
                    templateID: templateID,
                    onProgress: { phase in
                        guard case .downloading(let received, let expected) = phase, expected > 0 else { return }
                        let fraction = min(1, max(0, Double(received) / Double(expected)))
                        Task { @MainActor in
                            EnvironmentTemplateJobs.shared.fractions[templateID] = fraction
                        }
                    }
                )
                messages[templateID] = String(localized: "template.verified_registered")
            } catch {
                messages[templateID] = error.localizedDescription
                failures.insert(templateID)
            }
            preparing.remove(templateID)
            prepareTasks[templateID] = nil
            revision += 1
        }
    }

    func cancelPrepare(templateID: String) {
        messages[templateID] = String(localized: "template.cancelling")
        prepareTasks[templateID]?.cancel()
        Task { await FloePlatformServices.shared.cancelPrepareOfficialTemplate(templateID: templateID) }
    }

    func create(
        templateID: String,
        workspaceRootURL: URL,
        name: String?,
        rememberWorkspaceAccess: @MainActor @Sendable (URL, String?) async throws -> Void
    ) async throws -> EnvironmentRegistry.PinnedEnvironmentCreation {
        creating.insert(templateID)
        defer { creating.remove(templateID); revision += 1 }
        return try await FloePlatformServices.shared.createPinnedEnvironment(
            templateID: templateID, workspaceRootURL: workspaceRootURL, name: name,
            rememberWorkspaceAccess: rememberWorkspaceAccess
        )
    }
}

struct EnvironmentTemplatesView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var availabilities: [RuntimeV2OfficialTemplateAvailability] = []
    @State private var loading = false
    @State private var error: String?
    @State private var creationTemplate: RuntimeV2OfficialTemplateAvailability?
    @ObservedObject private var jobs = EnvironmentTemplateJobs.shared

    var body: some View {
        List {
            Section {
                Text("template.intro")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading && availabilities.isEmpty { ProgressView("template.loading_status") }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive)
                    Button("template.retry") { Task { await reload() } }
                }
            }
            ForEach(availabilities, id: \.templateID) { availability in
                Section {
                    templateRow(availability)
                } header: {
                    Text(Self.displayName(availability.templateID))
                } footer: {
                    Text(Self.summary(availability.templateID)).font(.caption)
                }
            }
        }
        .navigationTitle(FloeL10n.l("template.list_title"))
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: jobs.revision) { Task { await reload() } }
        .sheet(isPresented: Binding(
            get: { creationTemplate != nil },
            set: { if !$0 { creationTemplate = nil } }
        )) {
            if let template = creationTemplate {
                EnvironmentTemplateCreationSheet(template: template) { root, name in
                    // Persist durable access to the picked external folder
                    // first, through the same WorkspaceRecord/bookmark
                    // mechanism the Files workspace flow uses. The
                    // fileImporter's security scope only lives for this
                    // submit; the bookmark is what keeps the workspace
                    // resolvable after relaunch, and an existing record for
                    // the folder is reused instead of duplicated.
                    try await jobs.create(
                        templateID: template.templateID,
                        workspaceRootURL: root,
                        name: name
                    ) { url, recordName in
                        _ = try await environment.workspaceCenter.ensureWorkspaceRecord(
                            forDirectory: url,
                            name: recordName
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder private func templateRow(_ availability: RuntimeV2OfficialTemplateAvailability) -> some View {
        switch availability.state {
        case .verified:
            VStack(alignment: .leading, spacing: 6) {
                Label("template.verified", systemImage: "checkmark.seal.fill").foregroundStyle(FloeTheme.primary)
                if let version = availability.version, let digest = availability.digest {
                    Text(String.localizedStringWithFormat(
                        String(localized: "template.version_digest"),
                        version,
                        String(digest.prefix(16))
                    ))
                        .font(.caption).monospaced()
                }
                if let count = availability.packageCount {
                    Text(String.localizedStringWithFormat(
                        String(localized: "template.packages_installed"),
                        Int64(count)
                    ))
                        .font(.caption)
                    Text(packageSummary(availability))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    creationTemplate = availability
                } label: {
                    Label("template.new_from", systemImage: "plus.square.on.square")
                }
                .disabled(jobs.creating.contains(availability.templateID))
            }
        case .available:
            VStack(alignment: .leading, spacing: 6) {
                Label("template.available", systemImage: "arrow.down.circle")
                if let bytes = availability.archiveBytes {
                    Text(String.localizedStringWithFormat(
                        String(localized: "template.archive_size"),
                        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    ))
                        .font(.caption)
                }
                if jobs.preparing.contains(availability.templateID) {
                    if let fraction = jobs.fractions[availability.templateID] {
                        ProgressView(value: fraction) {
                            Text(String.localizedStringWithFormat(
                                String(localized: "template.downloading_pct"),
                                Int64(fraction * 100)
                            ))
                        }
                    } else {
                        ProgressView("template.preparing")
                    }
                    Button(role: .destructive) {
                        jobs.cancelPrepare(templateID: availability.templateID)
                    } label: {
                        Label("template.cancel", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        jobs.prepare(templateID: availability.templateID)
                    } label: {
                        Label("template.download_register", systemImage: "arrow.down.circle")
                    }
                }
            }
        case .registeredNotVerified:
            VStack(alignment: .leading, spacing: 6) {
                Label("template.registered_unverified", systemImage: "exclamationmark.triangle")
                Text(availability.reason ?? String(localized: "template.unverified_reason_default"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .dependencyMissing:
            VStack(alignment: .leading, spacing: 6) {
                Label("template.dependency_missing", systemImage: "clock.badge.exclamationmark")
                Text(availability.reason ?? String(localized: "template.dependency_missing_default"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let message = jobs.messages[availability.templateID], !message.isEmpty {
            Text(message)
                .font(.caption)
                .foregroundStyle(jobs.failures.contains(availability.templateID) ? FloeTheme.destructive : .secondary)
        }
    }

    private func packageSummary(_ availability: RuntimeV2OfficialTemplateAvailability) -> String {
        let names = availability.packageNames
        guard !names.isEmpty else { return "" }
        let shown = names.prefix(12).joined(separator: ", ")
        return names.count > 12 ? "\(shown), …" : shown
    }

    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            availabilities = try await FloePlatformServices.shared.officialTemplateAvailability()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func displayName(_ templateID: String) -> String {
        switch templateID {
        case "basic": return String(localized: "template.basic")
        case "dev-document": return String(localized: "template.dev_document")
        default: return templateID
        }
    }

    static func summary(_ templateID: String) -> String {
        switch templateID {
        case "basic":
            return String(localized: "template.summary.basic")
        case "dev-document":
            return String(localized: "template.summary.dev_document")
        default:
            return templateID
        }
    }
}

private struct EnvironmentTemplateCreationSheet: View {
    let template: RuntimeV2OfficialTemplateAvailability
    /// Main-actor because the durable-access step reaches the app-lifetime
    /// `WorkspaceCenter` (WorkspaceRecord/bookmark store).
    let create: @MainActor (URL, String?) async throws -> EnvironmentRegistry.PinnedEnvironmentCreation
    @Environment(\.dismiss) private var dismiss
    @State private var workspaceURL: URL?
    @State private var name = ""
    @State private var pickingDirectory = false
    @State private var busy = false
    @State private var error: String?
    @State private var created: EnvironmentRegistry.PinnedEnvironmentCreation?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("template.name_label", value: EnvironmentTemplatesView.displayName(template.templateID))
                    if let version = template.version, let digest = template.digest {
                        LabeledContent("template.version_label", value: "\(version)")
                        LabeledContent("template.digest_label", value: String(digest.prefix(24)) + "…")
                    }
                } header: {
                    Text("template.section")
                }
                Section {
                    Button {
                        pickingDirectory = true
                    } label: {
                        Label(workspaceURL?.path ?? String(localized: "template.choose_folder"), systemImage: "folder")
                    }
                    TextField("template.env_name_optional", text: $name)
                } header: {
                    Text("template.workspace")
                }
                Section {
                    Text("template.pin_note")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive) }
                }
                if let created {
                    Section {
                        Text(String.localizedStringWithFormat(
                            String(localized: "template.created_line"),
                            String(created.record.id.prefix(8)),
                            created.record.templateVersion.map(String.init) ?? "-"
                        ))
                            .font(.caption).monospaced()
                        if !created.ownsWorkspaceRoot {
                            Text("template.parallel_note")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("template.created_section")
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if busy { ProgressView() } else { Text("template.create") }
                    }
                    .disabled(busy || workspaceURL == nil)
                }
            }
            .navigationTitle(FloeL10n.l("template.new_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("template.close") { dismiss() }
                }
            }
            .fileImporter(isPresented: $pickingDirectory, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { workspaceURL = url }
            }
        }
    }

    @MainActor private func submit() async {
        guard let workspaceURL else { return }
        let scoped = workspaceURL.startAccessingSecurityScopedResource()
        defer { if scoped { workspaceURL.stopAccessingSecurityScopedResource() } }
        busy = true
        defer { busy = false }
        do {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            created = try await create(workspaceURL, trimmed.isEmpty ? nil : trimmed)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
