#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeGit

import FloeCore
struct GitHubSettingsView: View {
    @ObservedObject var center: SourceControlCenter
    @Environment(\.openURL) private var openURL
    @State private var token = ""
    @State private var includeWorkflows = false
    @State private var showCreateRepository = false
    @State private var repositoryName = ""
    @State private var repositoryDescription = ""
    @State private var repositoryIsPrivate = true
    @State private var cloneTarget: GitHubRepository?

    var body: some View {
        Form {
            Section("settings.git_hub_settings_view.github_connection") {
                if let account = center.account {
                    LabeledContent("settings.git_hub_settings_view.account") {
                        Label(account.login, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(FloeTheme.success)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Button("action.disconnect", role: .destructive) {
                        do { try center.disconnect() }
                        catch { center.errorMessage = error.localizedDescription }
                    }
                } else {
                    if let authorization = center.deviceAuthorization {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("settings.git_hub_settings_view.enter_the_code_on_github")
                                .font(.headline)
                            Text(authorization.userCode)
                                .font(.system(.title2, design: .monospaced).weight(.bold))
                                .textSelection(.enabled)
                            HStack {
                                Button("settings.git_hub_settings_view.open_github_authorization_page") {
                                    openURL(authorization.verificationURL)
                                }
                                .buttonStyle(.borderedProminent)
                                Button("workspace.workspace_canvas_view.cancel", role: .cancel) {
                                    center.cancelDeviceLogin()
                                }
                            }
                            Text("settings.git_hub_settings_view.the_connection_completes_automatically_after_authorization")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Toggle(isOn: $includeWorkflows) {
                            Text(String(localized: "github.auth.workflows", defaultValue: "Allow GitHub Actions workflow setup"))
                        }
                        .disabled(center.isBusy)
                        Text(String(localized: "github.auth.workflows.detail", defaultValue: "Enable this when installing build templates. Existing credentials are unchanged until you sign in again."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await center.startDeviceLogin(includeWorkflows: includeWorkflows) }
                        } label: {
                            Label("settings.git_hub_settings_view.sign_in_to_github", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(center.isBusy)
                    }
                    DisclosureGroup(FloeL10n.l("settings.git_hub_settings_view.use_access_token_advanced")) {
                    Text("settings.git_hub_settings_view.access_token")
                        .font(.subheadline.weight(.medium))
                    SecureField("settings.git_hub_settings_view.github_fine_grained_access_token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .disabled(center.isDeviceLoginPending)
                    Button("settings.git_hub_settings_view.verify_and_connect") {
                        let value = token
                        Task {
                            do {
                                try await center.connect(token: value)
                                token = ""
                            } catch {
                                token = ""
                                center.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(
                        token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || center.isBusy
                            || center.isDeviceLoginPending
                    )
                    }
                }
                Text("settings.git_hub_settings_view.sign_in_credentials_are_kept_only")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }

            if center.isGitHubConnected {
                Section {
                    Button { showCreateRepository = true } label: {
                        Label("settings.git_hub_settings_view.new_github_repository", systemImage: "plus.square.on.square")
                    }
                    Button {
                        Task { await center.loadConnection() }
                    } label: {
                        Label("settings.git_hub_settings_view.refresh_repository_list", systemImage: "arrow.clockwise")
                    }
                }

                Section("settings.git_hub_settings_view.cloud_repository") {
                    if center.repositories.isEmpty {
                        Text("settings.git_hub_settings_view.the_current_account_has_no_accessible").foregroundStyle(.secondary)
                    }
                    ForEach(center.repositories) { repository in
                        Button { cloneTarget = repository } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(repository.fullName).lineLimit(1)
                                    Spacer()
                                    Text(repository.isPrivate ? "settings.git_hub_settings_view.private" : "settings.git_hub_settings_view.public")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                HStack {
                                    Label(repository.defaultBranch, systemImage: "arrow.triangle.branch")
                                    Spacer()
                                    Text("settings.git_hub_settings_view.clone_into_current_workspace")
                                }
                                .font(.caption)
                                .foregroundStyle(FloeTheme.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(FloeL10n.l("settings.git_hub_settings_view.github_source_control"))
        .task { await center.loadConnection() }
        .overlay { if center.isBusy { ProgressView().controlSize(.large) } }
        .alert("settings.git_hub_settings_view.github_connection_error", isPresented: Binding(
            get: { center.errorMessage != nil },
            set: { if !$0 { center.errorMessage = nil } }
        )) {
            Button("workspace.office_document_editor_view.ok", role: .cancel) { center.errorMessage = nil }
        } message: {
            Text(center.errorMessage ?? "")
        }
        .confirmationDialog("settings.git_hub_settings_view.clone_repository",
            isPresented: Binding(get: { cloneTarget != nil }, set: { if !$0 { cloneTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("settings.git_hub_settings_view.clone_into_current_workspace") {
                guard let repository = cloneTarget else { return }
                cloneTarget = nil
                Task { await center.perform { try await center.clone(repository) } }
            }
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) { cloneTarget = nil }
        } message: {
            Text(cloneTarget.map { FloeL10n.l("settings.git_hub_settings_view.will_create_subfolder", $0.name) } ?? "")
        }
        .sheet(isPresented: $showCreateRepository) { createRepositorySheet }
    }

    private var createRepositorySheet: some View {
        NavigationStack {
            Form {
                TextField("settings.git_hub_settings_view.repository_name", text: $repositoryName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("settings.git_hub_settings_view.description_optional", text: $repositoryDescription, axis: .vertical)
                Toggle("settings.git_hub_settings_view.private_repository", isOn: $repositoryIsPrivate)
            }
            .navigationTitle(FloeL10n.l("settings.git_hub_settings_view.new_github_repository"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("workspace.workspace_canvas_view.cancel") { showCreateRepository = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("settings.git_hub_settings_view.create") {
                        let name = repositoryName
                        let description = repositoryDescription
                        let isPrivate = repositoryIsPrivate
                        showCreateRepository = false
                        Task {
                            await center.perform {
                                try await center.createGitHubRepository(
                                    name: name, isPrivate: isPrivate, description: description
                                )
                                repositoryName = ""
                                repositoryDescription = ""
                                repositoryIsPrivate = true
                            }
                        }
                    }
                    .disabled(repositoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
#endif
